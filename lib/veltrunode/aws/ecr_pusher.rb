# frozen_string_literal: true

require 'base64'
require 'open3'
require 'yaml'
require_relative '../compiler/logical_id'
require_relative '../build/container_runner'

module Veltrunode
  module AWS
    class EcrPushError < Veltrunode::Error
      attr_reader :repository, :image_uri, :original_error

      def initialize(message, repository: nil, image_uri: nil, original_error: nil)
        super(message)
        @repository = repository
        @image_uri = image_uri
        @original_error = original_error
      end
    end

    class EcrPushResult
      attr_reader :function_name, :repository_name, :repository_uri, :image_tag, :image_uri, :image_digest, :status

      def initialize(function_name:, repository_name:, repository_uri:, image_tag:, image_uri:,
                     image_digest: nil, status: :pushed)
        @function_name = function_name.to_s.freeze
        @repository_name = repository_name.to_s.freeze
        @repository_uri = repository_uri.to_s.freeze
        @image_tag = image_tag.to_s.freeze
        @image_uri = image_uri.to_s.freeze
        @image_digest = image_digest&.to_s&.freeze
        @status = status.to_sym

        freeze
      end

      def pushed?
        @status == :pushed
      end

      def skipped?
        @status == :skipped
      end

      def to_h
        {
          'function_name' => @function_name,
          'repository_name' => @repository_name,
          'repository_uri' => @repository_uri,
          'image_tag' => @image_tag,
          'image_uri' => @image_uri,
          'image_digest' => @image_digest,
          'status' => @status.to_s
        }.compact
      end
    end

    class EcrPusher
      DEFAULT_REGION = 'ap-northeast-1'
      DIGEST_REGEX = /sha256:[0-9a-f]{64}/i

      class << self
        def push_build_result(build_result, **)
          new(**).push_build_result(build_result)
        end

        def push_and_update_template(build_result, **)
          new(**).push_and_update_template(build_result)
        end
      end

      attr_reader :application, :region, :account_id, :runner_executable, :command_runner

      def initialize(
        application: nil,
        region: nil,
        account_id: nil,
        ecr_client: nil,
        runner_executable: nil,
        command_runner: nil
      )
        @application = application
        @region = (region || extract_app_region || ENV['AWS_REGION'] || DEFAULT_REGION).to_s.freeze
        @account_id = (account_id || extract_app_account)&.to_s&.freeze
        @ecr_client = ecr_client
        @runner_executable = runner_executable
        @command_runner = command_runner
        @authenticated_registries = {}
      end

      def ensure_repository(repository_name)
        repo_str = repository_name.to_s.strip
        raise EcrPushError.new('ECR repository name cannot be empty.', repository: repository_name) if repo_str.empty?

        begin
          resp = client.describe_repositories(repository_names: [repo_str])
          repo = resp.respond_to?(:repositories) ? Array(resp.repositories).first : nil
          return extract_repository_uri(repo, repo_str) if repo
        rescue StandardError => e
          raise wrap_ecr_error(e, repo_str) unless repository_not_found_error?(e)
        end

        begin
          create_resp = client.create_repository(
            repository_name: repo_str,
            image_scanning_configuration: { scan_on_push: true },
            encryption_configuration: { encryption_type: 'AES256' }
          )
          created_repo = create_resp.respond_to?(:repository) ? create_resp.repository : nil
          extract_repository_uri(created_repo, repo_str)
        rescue StandardError => e
          raise wrap_ecr_error(e, repo_str)
        end
      end

      def authenticate_docker!(registry_endpoint = nil)
        resp = client.get_authorization_token
        auth_data = resp.respond_to?(:authorization_data) ? Array(resp.authorization_data).first : nil
        raise EcrPushError, 'Failed to obtain ECR authorization token: empty response.' unless auth_data

        raw_token = if auth_data.respond_to?(:authorization_token)
                      auth_data.authorization_token
                    elsif auth_data.is_a?(Hash)
                      auth_data[:authorization_token] || auth_data['authorization_token']
                    end
        decoded = Base64.decode64(raw_token.to_s)
        username, password = decoded.split(':', 2)

        proxy_ep = if auth_data.respond_to?(:proxy_endpoint)
                     auth_data.proxy_endpoint
                   elsif auth_data.is_a?(Hash)
                     auth_data[:proxy_endpoint] || auth_data['proxy_endpoint']
                   end
        endpoint = (registry_endpoint || proxy_ep || default_registry_url).to_s.sub(%r{\Ahttps?://}, '')

        return endpoint if @authenticated_registries[endpoint]

        exe = resolve_executable
        cmd = [exe, 'login', '--username', username.to_s, '--password-stdin', endpoint]
        run_command!(cmd, stdin_data: password.to_s, action: "docker login to #{endpoint}")

        @authenticated_registries[endpoint] = true
        endpoint
      rescue EcrPushError
        raise
      rescue StandardError => e
        raise EcrPushError.new(
          "ECR authentication failed: #{e.message}",
          original_error: e
        )
      end

      def push_image(local_image:, repository_name:, image_tag: 'latest', function_name: nil)
        repo_str = repository_name.to_s.strip
        tag_str = (image_tag && !image_tag.to_s.strip.empty? ? image_tag.to_s.strip : 'latest')
        fn_str = (function_name || repo_str).to_s

        repo_uri = ensure_repository(repo_str)
        remote_image_uri = "#{repo_uri}:#{tag_str}"
        registry_host = repo_uri.split('/').first

        authenticate_docker!(registry_host)

        exe = resolve_executable
        if local_image.to_s != remote_image_uri
          tag_cmd = [exe, 'tag', local_image.to_s, remote_image_uri]
          run_command!(tag_cmd, repository: repo_str, image_uri: remote_image_uri, action: 'docker tag')
        end

        push_cmd = [exe, 'push', remote_image_uri]
        stdout_str, = run_command!(push_cmd, repository: repo_str, image_uri: remote_image_uri, action: 'docker push')
        digest = stdout_str.to_s[DIGEST_REGEX]

        EcrPushResult.new(
          function_name: fn_str,
          repository_name: repo_str,
          repository_uri: repo_uri,
          image_tag: tag_str,
          image_uri: remote_image_uri,
          image_digest: digest,
          status: :pushed
        )
      end

      def push_build_result(build_result)
        results = []
        fn_results_map = {}

        if build_result.respond_to?(:function_results)
          Array(build_result.function_results).each do |res|
            fn_results_map[res.function_name.to_s] = res if res.respond_to?(:function_name)
          end
        end

        app = @application || (build_result.respond_to?(:application) ? build_result.application : nil)
        functions = app.respond_to?(:functions) ? Array(app.functions) : []

        if functions.any?
          functions.each do |fn|
            next unless fn.respond_to?(:image?) && fn.image?
            next unless fn.respond_to?(:image_dockerfile) && fn.image_dockerfile

            fn_name = fn.logical_name.to_s
            fn_res = fn_results_map[fn_name]
            repo_name = (fn.respond_to?(:image_repository) && fn.image_repository) || fn_name
            tag = (fn_res.respond_to?(:image_tag) && fn_res.image_tag) ||
                  (fn.respond_to?(:image_tag) && fn.image_tag) ||
                  'latest'
            local_img = (fn_res.respond_to?(:image_uri) && fn_res.image_uri) || "#{repo_name}:#{tag}"

            results << push_image(
              local_image: local_img,
              repository_name: repo_name,
              image_tag: tag,
              function_name: fn_name
            )
          end
        else
          fn_results_map.each_value do |fn_res|
            next unless fn_res.respond_to?(:image?) && fn_res.image?
            next unless fn_res.respond_to?(:dockerfile_path) && fn_res.dockerfile_path

            fn_name = fn_res.function_name.to_s
            tag = fn_res.image_tag || 'latest'
            local_img = fn_res.image_uri || "#{fn_name}:#{tag}"
            repo_name = local_img.include?(':') ? local_img.rpartition(':').first : fn_name

            results << push_image(
              local_image: local_img,
              repository_name: repo_name,
              image_tag: tag,
              function_name: fn_name
            )
          end
        end

        results
      end

      def update_template(template_data_or_path, push_results:)
        template_hash = load_template_hash(template_data_or_path)
        resources = template_hash['Resources'] || template_hash[:Resources] || {}

        Array(push_results).each do |res|
          apply_resource_image_reference(resources, res)
        end

        if template_data_or_path.is_a?(String) && File.file?(template_data_or_path)
          sorted_template = deep_sort_keys(template_hash)
          File.write(template_data_or_path, YAML.dump(sorted_template))
        end

        template_hash
      end

      def push_and_update_template(build_result)
        push_results = push_build_result(build_result)

        target = if build_result.respond_to?(:template_path) && File.file?(build_result.template_path.to_s)
                   build_result.template_path
                 elsif build_result.respond_to?(:template_data) && build_result.template_data.is_a?(Hash)
                   build_result.template_data
                 end

        updated_template = if target && !push_results.empty?
                             update_template(target, push_results: push_results)
                           elsif target
                             load_template_hash(target)
                           end

        {
          push_results: push_results,
          template: updated_template
        }
      end

      private

      def client
        @client ||= resolve_ecr_client
      end

      def resolve_ecr_client
        return @ecr_client if @ecr_client

        begin
          require 'aws-sdk-ecr' unless defined?(::Aws::ECR::Client)
          ::Aws::ECR::Client.new(region: @region)
        rescue LoadError => e
          raise EcrPushError, "AWS SDK (aws-sdk-ecr) is not available: #{e.message}. Please install aws-sdk-ecr."
        end
      end

      def resolve_executable
        return @runner_executable if @runner_executable && !@runner_executable.to_s.strip.empty?
        return Veltrunode::Build::ContainerRunner.validate_runtime_available! if @command_runner.nil?

        Veltrunode::Build::ContainerRunner.detect_executable || 'docker'
      end

      def run_command!(cmd, stdin_data: nil, repository: nil, image_uri: nil, action: 'docker command')
        stdout_str, stderr_str, status = if @command_runner
                                           @command_runner.call(cmd, stdin_data: stdin_data)
                                         elsif stdin_data
                                           Open3.capture3(*cmd, stdin_data: stdin_data)
                                         else
                                           Open3.capture3(*cmd)
                                         end

        success = status.respond_to?(:success?) ? status.success? : status == true
        return [stdout_str.to_s, stderr_str.to_s] if success

        exit_code = status.respond_to?(:exitstatus) ? status.exitstatus : 1
        raise EcrPushError.new(
          "Failed to execute #{action} (exit code #{exit_code}): #{stderr_str.to_s.strip}",
          repository: repository,
          image_uri: image_uri
        )
      end

      def extract_repository_uri(repo_obj, fallback_name)
        uri = if repo_obj.respond_to?(:repository_uri)
                repo_obj.repository_uri
              elsif repo_obj.is_a?(Hash)
                repo_obj[:repository_uri] || repo_obj['repository_uri']
              end
        return uri.to_s if uri && !uri.to_s.strip.empty?

        "#{default_registry_url}/#{fallback_name}"
      end

      def default_registry_url
        acct = @account_id || '123456789012'
        "#{acct}.dkr.ecr.#{@region}.amazonaws.com"
      end

      def repository_not_found_error?(err)
        err.class.name.include?('RepositoryNotFoundException') ||
          err.message.to_s.include?('RepositoryNotFoundException') ||
          err.message.to_s.include?('does not exist in the registry')
      end

      def wrap_ecr_error(err, repository_name)
        return err if err.is_a?(EcrPushError)

        EcrPushError.new(
          "ECR operation failed for repository '#{repository_name}': #{err.message}",
          repository: repository_name,
          original_error: err
        )
      end

      def extract_app_region
        return nil unless @application

        if @application.respond_to?(:region) && @application.region
          @application.region
        elsif @application.is_a?(Hash)
          @application[:region] || @application['region']
        end
      end

      def extract_app_account
        return nil unless @application

        if @application.respond_to?(:account_constraint) && @application.account_constraint
          @application.account_constraint
        elsif @application.respond_to?(:account) && @application.account
          @application.account
        elsif @application.is_a?(Hash)
          @application[:account_constraint] || @application['account_constraint'] ||
            @application[:account] || @application['account']
        end
      end

      def load_template_hash(template_data_or_path)
        case template_data_or_path
        when Hash
          template_data_or_path
        when String
          if File.file?(template_data_or_path)
            YAML.safe_load_file(template_data_or_path, aliases: true) || {}
          else
            YAML.safe_load(template_data_or_path, aliases: true) || {}
          end
        else
          raise ArgumentError, "Invalid template input: #{template_data_or_path.class}"
        end
      end

      def apply_resource_image_reference(resources, res)
        logical_id = Veltrunode::Compiler::LogicalId.for_function(res.function_name)
        fn_res = resources[logical_id] || resources[logical_id.to_sym]
        return unless fn_res.is_a?(Hash)

        props = (fn_res['Properties'] ||= {})
        props['PackageType'] = 'Image'
        props['Code'] = {
          'ImageUri' => res.image_uri
        }
      end

      def deep_sort_keys(obj)
        case obj
        when Hash
          obj.keys.sort_by(&:to_s).to_h do |k|
            [k.to_s, deep_sort_keys(obj[k])]
          end
        when Array
          obj.map { |v| deep_sort_keys(v) }
        else
          obj
        end
      end
    end
  end
end
