# frozen_string_literal: true

require 'spec_helper'
require 'rantly'
require 'rantly/rspec_extensions'

RSpec.describe 'Property-based Testing' do
  # ---------------------------------------------------------------------------
  # Helpers for verifying sorted keys in arbitrary structures
  # ---------------------------------------------------------------------------
  def assert_all_keys_sorted(obj)
    case obj
    when Hash
      expect(obj.keys).to eq(obj.keys.sort)
      expect(obj.keys.all?(String)).to be true
      obj.each_value { |v| assert_all_keys_sorted(v) }
    when Array
      obj.each { |item| assert_all_keys_sorted(item) }
    end
  end

  # ---------------------------------------------------------------------------
  # 1. CloudFormation Compilation Determinism
  # ---------------------------------------------------------------------------
  describe 'CloudFormation Compilation Determinism' do
    it 'produces identical CloudFormation templates and hashes across repeated compilations' do
      prop = property_of do
        Rantly do
          app_name = "#{choose(*%w[order billing inventory notify report auth])}_#{range(100, 999)}"
          region_choice = choose('ap-northeast-1', 'us-east-1', 'eu-west-1')
          stage_choice = choose('dev', 'staging', 'prod')

          fn_count = range(1, 3)
          functions = fn_count.times.map do |i|
            fn_name = "#{choose(*%w[process ingest sync clean dispatch])}_#{i}_#{range(10, 99)}"
            runtime_choice = choose('ruby3.3', 'ruby3.4', 'python3.11', 'python3.12', 'nodejs20.x')
            arch_choice = choose(:arm64, :x86_64)
            mem_choice = choose(128, 256, 512, 1024)
            timeout_choice = choose(10, 30, 60, 120)

            env_vars = {}
            range(0, 2).times do |e_i|
              env_vars["VAR_#{e_i}"] = "value_#{range(1, 100)}"
            end

            caps = []
            if boolean
              caps << {
                type: :read_from_s3,
                params: { bucket: "bucket-#{range(1, 100)}", prefix: 'data/' }
              }
            end
            if boolean
              caps << {
                type: :read_parameter,
                params: { path: "/app/config/#{range(1, 50)}/*" }
              }
            end

            Veltrunode::Model::Function.new(
              logical_name: fn_name,
              handler: 'app.handler',
              runtime: runtime_choice,
              architecture: arch_choice,
              memory: mem_choice,
              timeout: timeout_choice,
              environment: env_vars,
              iam_capabilities: caps
            )
          end

          schedules = []
          if boolean
            target_fn = functions.sample.logical_name
            schedules << Veltrunode::Model::Schedule.new(
              name: "cron_#{range(10, 99)}",
              target_function: target_fn,
              expression_type: :cron,
              expression: '0 0 * * ? *'
            )
          end

          Veltrunode::Model::Application.new(
            name: app_name,
            region: region_choice,
            stage: stage_choice,
            account_constraint: '123456789012',
            functions: functions,
            schedules: schedules
          )
        end
      end

      prop.check(25) do |app|
        yaml1 = Veltrunode::Compiler::CloudFormation.to_yaml(app)
        yaml2 = Veltrunode::Compiler::CloudFormation.to_yaml(app)
        expect(yaml1).to eq(yaml2)

        hash1 = Veltrunode::Compiler::CloudFormation.compile(app)
        hash2 = Veltrunode::Compiler::CloudFormation.compile(app)
        expect(hash1).to eq(hash2)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Map Key Stable Sorting
  # ---------------------------------------------------------------------------
  describe 'Map Key Stable Sorting' do
    let(:compiler_instance) do
      minimal_app = Veltrunode::Model::Application.new(name: 'dummy', region: 'ap-northeast-1', stage: 'dev')
      Veltrunode::Compiler::CloudFormation::TemplateCompiler.new(minimal_app)
    end

    gen_nested_hash = lambda do |r, depth = 0|
      return r.choose(r.string, r.integer, r.boolean) if depth > 3

      count = r.range(1, 4)
      res = {}
      count.times do
        k = r.choose(r.string(:alnum), :sym)
        v = r.choose(
          r.string(:alnum),
          r.integer,
          r.boolean,
          gen_nested_hash.call(r, depth + 1),
          Array.new(r.range(1, 3)) { gen_nested_hash.call(r, depth + 1) }
        )
        res[k] = v
      end
      res
    end

    it 'ensures all keys in nested dictionaries are stringified and alphabetically sorted at all depths' do
      prop = property_of do
        gen_nested_hash.call(self)
      end

      prop.check(50) do |raw_hash|
        sorted = compiler_instance.send(:deep_sort_keys, raw_hash)
        assert_all_keys_sorted(sorted)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. File Path Normalization
  # ---------------------------------------------------------------------------
  describe 'File Path Normalization' do
    it 'removes redundant slashes, current directory dots, and parent directory segments idempotently' do
      prop = property_of do
        Rantly do
          segments = range(1, 5).times.map { choose(*%w[app lib models controllers test dist out cache]) }
          is_abs = boolean

          # Interleave redundant slashes and current-dir dots
          parts = segments.map do |seg|
            prefix = choose('', './', './/')
            suffix = choose('', '/', '//')
            "#{prefix}#{seg}#{suffix}"
          end

          raw_path = parts.join(choose('/', '//', '///'))
          raw_path = "/#{raw_path}" if is_abs
          raw_path
        end
      end

      prop.check(50) do |raw_path|
        normalized = Veltrunode::PathNormalizer.normalize(raw_path)

        expect(normalized).not_to include('//')
        expect(normalized).not_to include('/./')
        expect(normalized).not_to end_with('/.')

        expect(normalized).not_to end_with('/') unless ['.', '/'].include?(normalized)

        # Idempotency property: normalize(normalize(p)) == normalize(p)
        expect(Veltrunode::PathNormalizer.normalize(normalized)).to eq(normalized)
        expect(Veltrunode.normalize_path(raw_path)).to eq(normalized)

        # Absolute vs Relative preservation
        if raw_path.start_with?('/')
          expect(normalized).to start_with('/')
        else
          expect(normalized).not_to start_with('/')
        end
      end
    end

    it 'handles empty and nil paths safely' do
      expect(Veltrunode::PathNormalizer.normalize(nil)).to eq('')
      expect(Veltrunode::PathNormalizer.normalize('')).to eq('')
      expect(Veltrunode::PathNormalizer.normalize('   ')).to eq('')
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Logical ID Uniqueness and Validity
  # ---------------------------------------------------------------------------
  describe 'Logical ID Uniqueness and Validity' do
    it 'generates valid CloudFormation alphanumeric identifiers for arbitrary inputs' do
      prop = property_of do
        Rantly do
          words = range(1, 3).times.map { choose(*%w[user auth token order sync convert task run job v1 v2]) }
          delimiter = choose('_', '-', '.', ' ')
          raw_name = words.join(delimiter)
          type = choose(:function, :layer, :layer_version, :schedule, :queue, :log_group, :role)
          [raw_name, type]
        end
      end

      prop.check(50) do |raw_name, type|
        logical_id = Veltrunode::Compiler::LogicalId.for(raw_name, type: type)

        # Must be non-empty alphanumeric string starting with a letter
        expect(logical_id).to match(/\A[A-Z][a-zA-Z0-9]*\z/)

        # Deterministic
        expect(Veltrunode::Compiler::LogicalId.for(raw_name, type: type)).to eq(logical_id)
      end
    end

    it 'generates distinct logical IDs for distinct symbolic names of the same resource type' do
      prop = property_of do
        Rantly do
          count = range(5, 12)
          names = []
          while names.size < count
            candidate = "#{choose(*%w[apple banana cherry date elderberry fig grape])}_#{range(1, 10_000)}"
            names << candidate unless names.include?(candidate)
          end
          type = choose(:function, :layer, :schedule, :queue)
          [names, type]
        end
      end

      prop.check(25) do |names, type|
        ids = names.map { |n| Veltrunode::Compiler::LogicalId.for(n, type: type) }
        expect(ids.uniq.size).to eq(names.size)
      end
    end

    it 'generates distinct logical IDs across different resource types for the same name' do
      prop = property_of do
        Rantly { "#{choose(*%w[order worker payment report sync])}_#{range(1, 1000)}" }
      end

      prop.check(25) do |name|
        fn_id = Veltrunode::Compiler::LogicalId.for_function(name)
        layer_id = Veltrunode::Compiler::LogicalId.for_layer(name)
        sched_id = Veltrunode::Compiler::LogicalId.for_schedule(name)
        queue_id = Veltrunode::Compiler::LogicalId.for_queue(name)
        log_id = Veltrunode::Compiler::LogicalId.for_log_group(name)

        ids = [fn_id, layer_id, sched_id, queue_id, log_id]
        expect(ids.uniq.size).to eq(ids.size)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Reference Resolution Idempotency
  # ---------------------------------------------------------------------------
  describe 'Reference Resolution Idempotency' do
    it 'produces stable and idempotent dependency graphs and topological build orders' do
      prop = property_of do
        Rantly do
          layer_count = range(1, 3)
          layers = layer_count.times.map do |i|
            Veltrunode::Model::Layer.new(
              name: "shared_layer_#{i}",
              compatible_runtimes: ['ruby3.3']
            )
          end

          mount_count = range(0, 2)
          mounts = mount_count.times.map do |i|
            ap_source = "arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-#{i}234567890ab"
            Veltrunode::Model::EfsMount.new(
              symbolic_name: "efs_store_#{i}",
              access_point_source: ap_source,
              local_path: "/mnt/data_#{i}"
            )
          end

          fn_count = range(1, 3)
          functions = fn_count.times.map do |i|
            attached_layers = layers.sample(range(0, layers.size)).map(&:name)
            attached_mounts = mounts.sample(range(0, mounts.size)).map(&:symbolic_name)
            vpc_ref = attached_mounts.empty? ? nil : { security_group_ids: ['sg-1'], subnet_ids: ['sub-1'] }

            Veltrunode::Model::Function.new(
              logical_name: "fn_worker_#{i}",
              handler: 'app.handler',
              runtime: 'ruby3.3',
              layers: attached_layers,
              mounts: attached_mounts,
              vpc_reference: vpc_ref
            )
          end

          schedules = functions.sample(range(0, functions.size)).map.with_index do |fn, i|
            Veltrunode::Model::Schedule.new(
              name: "sched_#{i}",
              target_function: fn.logical_name,
              expression_type: :cron,
              expression: '0 0 * * ? *'
            )
          end

          Veltrunode::Model::Application.new(
            name: "graph_app_#{range(1, 1000)}",
            region: 'ap-northeast-1',
            stage: 'dev',
            layers: layers,
            mounts: mounts,
            functions: functions,
            schedules: schedules
          )
        end
      end

      prop.check(25) do |app|
        graph = Veltrunode::Graph::ResourceGraph.new(app)

        # Graph build_order idempotency
        order1 = graph.build_order.map { |n| graph.send(:extract_name_string, n) }
        order2 = graph.build_order.map { |n| graph.send(:extract_name_string, n) }
        expect(order1).to eq(order2)

        # Function dependencies idempotency
        app.functions.each do |fn|
          deps1 = graph.depends_on_names(fn)
          deps2 = graph.depends_on_names(fn)
          expect(deps1).to eq(deps2)

          # Function lookup idempotency
          fn_name = fn.logical_name
          expect(app.functions[fn_name]).to be(fn)
          expect(app.functions[fn_name]).to be(app.functions[fn_name])
        end

        # Schedules target function resolution idempotency
        app.schedules.each do |sched|
          deps1 = graph.depends_on_names(sched)
          deps2 = graph.depends_on_names(sched)
          expect(deps1).to eq(deps2)
          expect(deps1).to eq([sched.target_function])
        end
      end
    end
  end
end
