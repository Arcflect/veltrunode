# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Veltrunode::Graph::ResourceGraph do
  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'gems_layer',
      compatible_runtimes: ['ruby3.3']
    )
  end

  let(:mount) do
    Veltrunode::Model::EfsMount.new(
      symbolic_name: 'shared_storage',
      access_point_source: 'arn:aws:elasticfilesystem:ap-northeast-1:123456789012:access-point/fsap-123456',
      local_path: '/mnt/shared'
    )
  end

  let(:function) do
    Veltrunode::Model::Function.new(
      logical_name: 'converter_fn',
      handler: 'app.handler',
      runtime: 'ruby3.3',
      layers: ['gems_layer'],
      mounts: ['shared_storage']
    )
  end

  let(:schedule) do
    Veltrunode::Model::Schedule.new(
      name: 'daily_trigger',
      target_function: 'converter_fn',
      expression_type: :cron,
      expression: '0 0 * * ? *'
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'test_app',
      region: 'ap-northeast-1',
      stage: 'dev',
      layers: [layer],
      mounts: [mount],
      functions: [function],
      schedules: [schedule]
    )
  end

  describe '.build and #build_order' do
    it 'resolves symbolic references and orders dependencies first in topological sort' do
      graph = described_class.build(application)

      order = graph.build_order
      expect(order.size).to eq(4)

      # Layers and mounts should come before functions that depend on them
      gems_index = order.index(layer)
      mount_index = order.index(mount)
      fn_index = order.index(function)
      sched_index = order.index(schedule)

      expect(gems_index).to be < fn_index
      expect(mount_index).to be < fn_index
      expect(fn_index).to be < sched_index
    end

    it 'retrieves direct dependencies via #depends_on' do
      graph = described_class.build(application)

      fn_deps = graph.depends_on(function)
      expect(fn_deps).to contain_exactly(layer, mount)

      sched_deps = graph.depends_on(schedule)
      expect(sched_deps).to contain_exactly(function)

      layer_deps = graph.depends_on(layer)
      expect(layer_deps).to be_empty
    end

    it 'correctly normalizes symbol-based Hash layer and mount references' do
      hash_fn = Veltrunode::Model::Function.new(
        logical_name: 'hash_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        layers: [{ name: :gems_layer }],
        mounts: [{ name: :shared_storage, local_path: '/mnt/shared' }]
      )
      hash_app = Veltrunode::Model::Application.new(
        name: 'hash_app',
        region: 'ap-northeast-1',
        stage: 'dev',
        layers: [layer],
        mounts: [mount],
        functions: [hash_fn]
      )

      graph = described_class.build(hash_app)
      fn_deps = graph.depends_on(hash_fn)
      expect(fn_deps).to contain_exactly(layer, mount)
    end
  end

  describe 'unresolved reference validation (VLT-REF-001)' do
    it 'raises ValidationError when function references a non-existent layer' do
      invalid_fn = Veltrunode::Model::Function.new(
        logical_name: 'bad_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        layers: ['missing_layer']
      )
      invalid_app = Veltrunode::Model::Application.new(
        name: 'bad_app',
        region: 'ap-northeast-1',
        stage: 'dev',
        functions: [invalid_fn]
      )

      expect { described_class.build(invalid_app) }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-REF-001')
          expect(err.diagnostics.first.evidence['referenced_layer']).to eq('missing_layer')
        }
    end

    it 'raises ValidationError when function references a non-existent mount' do
      invalid_fn = Veltrunode::Model::Function.new(
        logical_name: 'bad_fn',
        handler: 'app.handler',
        runtime: 'ruby3.3',
        mounts: ['missing_mount']
      )
      invalid_app = Veltrunode::Model::Application.new(
        name: 'bad_app',
        region: 'ap-northeast-1',
        stage: 'dev',
        functions: [invalid_fn]
      )

      expect { described_class.build(invalid_app) }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-REF-001')
          expect(err.diagnostics.first.evidence['referenced_mount']).to eq('missing_mount')
        }
    end

    it 'raises ValidationError when schedule references a non-existent function' do
      invalid_sched = Veltrunode::Model::Schedule.new(
        name: 'bad_sched',
        target_function: 'missing_fn',
        expression_type: :cron,
        expression: '0 0 * * ? *'
      )
      invalid_app = Veltrunode::Model::Application.new(
        name: 'bad_app',
        region: 'ap-northeast-1',
        stage: 'dev',
        schedules: [invalid_sched]
      )

      expect { described_class.build(invalid_app) }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-REF-001')
          expect(err.diagnostics.first.evidence['referenced_function']).to eq('missing_fn')
        }
    end
  end

  describe 'circular dependency validation (VLT-GRAPH-001)' do
    it 'raises ValidationError when a circular dependency exists' do
      empty_app = Veltrunode::Model::Application.new(
        name: 'empty_app',
        region: 'ap-northeast-1',
        stage: 'dev'
      )
      graph = described_class.allocate
      graph.instance_variable_set(:@application, empty_app)
      graph.instance_variable_set(:@nodes, { 'fn_a' => function, 'fn_b' => function })
      graph.instance_variable_set(:@node_types, { 'fn_a' => :function, 'fn_b' => :function })
      graph.instance_variable_set(:@dependencies, { 'fn_a' => ['fn_b'], 'fn_b' => ['fn_a'] })
      graph.instance_variable_set(:@dependents, { 'fn_a' => ['fn_b'], 'fn_b' => ['fn_a'] })

      expect { graph.validate! }
        .to raise_error(Veltrunode::ValidationError) { |err|
          expect(err.diagnostics).not_to be_empty
          expect(err.diagnostics.first.code).to eq('VLT-GRAPH-001')
        }
    end
  end
end
