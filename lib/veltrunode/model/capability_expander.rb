# frozen_string_literal: true

require_relative '../diagnostics/diagnostic'

module Veltrunode
  module Model
    class CapabilityExpander
      MAPPING_VERSION = '1.0.0'

      class << self
        def expand(capability, context = {})
          new(context).expand(capability)
        end

        def expand_all(capabilities, context = {})
          new(context).expand_all(capabilities)
        end
      end

      attr_reader :context

      def initialize(context = {})
        @context = context.freeze
      end

      def expand_all(capabilities)
        Array(capabilities).flat_map { |cap| expand(cap) }
      end

      def expand(capability)
        cap = normalize_capability(capability)
        statements = case cap.type
                     when :read_from_s3
                       expand_read_from_s3(cap.params)
                     when :write_to_s3
                       expand_write_to_s3(cap.params)
                     when :read_parameter
                       expand_read_parameter(cap.params)
                     when :custom
                       expand_custom(cap.params)
                     else
                       raise ValidationError, "Unknown capability type: #{cap.type.inspect}"
                     end

        validate_statements!(statements)
        statements.freeze
      end

      def check_wildcards(statements)
        diagnostics = []
        stage = (context[:stage] || context['stage'] || 'dev').to_s.downcase
        is_prod = %w[prod production].include?(stage)

        statements.each do |stmt|
          actions = Array(stmt['Action'])
          resources = Array(stmt['Resource'])

          if actions.include?('*')
            code = is_prod ? 'VLT-IAM-WILDCARD-ACTION' : 'VLT-IAM-WARN-WILDCARD'
            severity = is_prod ? :error : :warning
            diagnostics << Diagnostics::Diagnostic.new(
              code: code,
              severity: severity,
              summary: "IAM statement uses wildcard '*' for actions.",
              suggested_action: 'Specify explicit IAM actions instead of wildcard.',
              evidence: { 'statement' => stmt }
            )
          end

          wildcard_arn = resources.any? do |r|
            s = r.to_s
            next false unless s.start_with?('arn:')

            parts = s.split(':', 6)
            parts[3] == '*' || parts[4] == '*'
          end

          next unless resources.include?('*') || wildcard_arn

          code = is_prod ? 'VLT-IAM-WILDCARD-RESOURCE' : 'VLT-IAM-WARN-WILDCARD'
          severity = is_prod ? :error : :warning
          diagnostics << Diagnostics::Diagnostic.new(
            code: code,
            severity: severity,
            summary: "IAM statement uses wildcard '*' for resource.",
            suggested_action: 'Specify specific resource ARNs instead of global wildcard.',
            evidence: { 'statement' => stmt }
          )
        end

        diagnostics
      end

      private

      def normalize_capability(cap)
        if cap.is_a?(Capability)
          cap
        elsif cap.is_a?(Hash)
          type = cap[:type] || cap['type']
          params = cap[:params] || cap['params'] || cap.reject { |k, _| %w[type].include?(k.to_s) }
          Capability.new(type:, params:)
        else
          raise ValidationError, "Invalid capability format: #{cap.inspect}"
        end
      end

      def expand_read_from_s3(params)
        bucket = fetch_param(params, :bucket)
        raise ValidationError, 'read_from_s3 capability requires bucket param' if blank?(bucket)

        prefix = fetch_param(params, :prefix) || ''
        prefix_str = prefix.to_s.empty? ? '*' : "#{prefix}*"

        bucket_arn = "arn:aws:s3:::#{bucket}"
        object_arn = "arn:aws:s3:::#{bucket}/#{prefix_str}"

        [
          {
            'Effect' => 'Allow',
            'Action' => ['s3:GetObject', 's3:ListBucket'],
            'Resource' => [bucket_arn, object_arn]
          }
        ]
      end

      def expand_write_to_s3(params)
        bucket = fetch_param(params, :bucket)
        raise ValidationError, 'write_to_s3 capability requires bucket param' if blank?(bucket)

        prefix = fetch_param(params, :prefix) || ''
        prefix_str = prefix.to_s.empty? ? '*' : "#{prefix}*"

        object_arn = "arn:aws:s3:::#{bucket}/#{prefix_str}"

        [
          {
            'Effect' => 'Allow',
            'Action' => ['s3:PutObject'],
            'Resource' => [object_arn]
          }
        ]
      end

      def expand_read_parameter(params)
        name = fetch_param(params, :name) || fetch_param(params, :path) || fetch_param(params, :parameter_name)
        raise ValidationError, 'read_parameter capability requires name or path param' if blank?(name)

        region = fetch_context(:region) || '*'
        account = fetch_context(:account) || '*'

        param_path = name.to_s.sub(%r{\A/}, '')
        param_arn = "arn:aws:ssm:#{region}:#{account}:parameter/#{param_path}"

        [
          {
            'Effect' => 'Allow',
            'Action' => ['ssm:GetParameter', 'ssm:GetParameters'],
            'Resource' => [param_arn]
          }
        ]
      end

      def expand_custom(params)
        actions = Array(fetch_param(params, :actions) || fetch_param(params, :action))
        resources = Array(fetch_param(params, :resources) || fetch_param(params, :resource))

        raise ValidationError, 'Custom IAM capability requires actions' if actions.empty?

        resources = ['*'] if resources.empty?

        [
          {
            'Effect' => 'Allow',
            'Action' => actions.map(&:to_s),
            'Resource' => resources.map(&:to_s)
          }
        ]
      end

      def validate_statements!(statements)
        diags = check_wildcards(statements)
        errors = diags.select { |d| d.severity == :error }
        return if errors.empty?

        first_err = errors.first
        raise ValidationError.new(first_err.summary, diagnostics: diags)
      end

      def fetch_param(params, key)
        return nil unless params.is_a?(Hash)

        params[key.to_sym] || params[key.to_s]
      end

      def fetch_context(key)
        return nil unless context.is_a?(Hash)

        context[key.to_sym] || context[key.to_s]
      end

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end
    end
  end
end
