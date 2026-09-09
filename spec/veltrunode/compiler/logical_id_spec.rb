# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/compiler/logical_id'

RSpec.describe Veltrunode::Compiler::LogicalId do
  describe '.pascalize' do
    it 'converts snake_case symbols and strings to PascalCase' do
      expect(described_class.pascalize(:convert)).to eq('Convert')
      expect(described_class.pascalize('runtime_gems')).to eq('RuntimeGems')
      expect(described_class.pascalize(:nightly_sync)).to eq('NightlySync')
    end

    it 'converts kebab-case to PascalCase' do
      expect(described_class.pascalize('doc-converter')).to eq('DocConverter')
      expect(described_class.pascalize('api-v2-worker')).to eq('ApiV2Worker')
    end

    it 'handles mixed delimiters (underscores, hyphens, dots, spaces, slashes)' do
      expect(described_class.pascalize('app.worker-service_v1/main')).to eq('AppWorkerServiceV1Main')
      expect(described_class.pascalize('user profile processor')).to eq('UserProfileProcessor')
    end

    it 'preserves existing PascalCase words' do
      expect(described_class.pascalize('ConvertFunction')).to eq('ConvertFunction')
      expect(described_class.pascalize('RuntimeGemsLayer')).to eq('RuntimeGemsLayer')
    end

    it 'handles nil and empty strings gracefully' do
      expect(described_class.pascalize(nil)).to eq('')
      expect(described_class.pascalize('')).to eq('')
      expect(described_class.pascalize('   ')).to eq('')
    end
  end

  describe '.for_function' do
    it 'generates PascalCase Function logical ID with Function suffix' do
      expect(described_class.for_function(:convert)).to eq('ConvertFunction')
      expect(described_class.for_function('worker_task')).to eq('WorkerTaskFunction')
    end

    it 'does not duplicate suffix when name already ends with Function' do
      expect(described_class.for_function('convert_function')).to eq('ConvertFunction')
      expect(described_class.for_function('ConvertFunction')).to eq('ConvertFunction')
    end

    it 'falls back to Function when input is empty' do
      expect(described_class.for_function('')).to eq('Function')
      expect(described_class.for_function(nil)).to eq('Function')
    end
  end

  describe '.for_layer' do
    it 'generates PascalCase Layer logical ID with Layer suffix' do
      expect(described_class.for_layer(:runtime_gems)).to eq('RuntimeGemsLayer')
      expect(described_class.for_layer('native_tools')).to eq('NativeToolsLayer')
    end

    it 'does not duplicate suffix when name already ends with Layer' do
      expect(described_class.for_layer('runtime_gems_layer')).to eq('RuntimeGemsLayer')
      expect(described_class.for_layer('RuntimeGemsLayer')).to eq('RuntimeGemsLayer')
    end

    it 'falls back to Layer when input is empty' do
      expect(described_class.for_layer('')).to eq('Layer')
      expect(described_class.for_layer(nil)).to eq('Layer')
    end
  end

  describe '.for_layer_version' do
    it 'generates PascalCase LayerVersion logical ID with LayerVersion suffix' do
      expect(described_class.for_layer_version(:runtime_gems)).to eq('RuntimeGemsLayerVersion')
      expect(described_class.for_layer_version('common')).to eq('CommonLayerVersion')
    end

    it 'does not duplicate suffix when name already ends with LayerVersion' do
      expect(described_class.for_layer_version('runtime_gems_layer_version')).to eq('RuntimeGemsLayerVersion')
      expect(described_class.for_layer_version('RuntimeGemsLayerVersion')).to eq('RuntimeGemsLayerVersion')
    end

    it 'falls back to LayerVersion when input is empty' do
      expect(described_class.for_layer_version('')).to eq('LayerVersion')
      expect(described_class.for_layer_version(nil)).to eq('LayerVersion')
    end
  end

  describe '.for_schedule' do
    it 'generates PascalCase Schedule logical ID with Schedule suffix' do
      expect(described_class.for_schedule(:nightly)).to eq('NightlySchedule')
      expect(described_class.for_schedule('daily_sync')).to eq('DailySyncSchedule')
    end

    it 'does not duplicate suffix when name already ends with Schedule' do
      expect(described_class.for_schedule('daily_sync_schedule')).to eq('DailySyncSchedule')
      expect(described_class.for_schedule('DailySyncSchedule')).to eq('DailySyncSchedule')
    end

    it 'falls back to Schedule when input is empty' do
      expect(described_class.for_schedule('')).to eq('Schedule')
      expect(described_class.for_schedule(nil)).to eq('Schedule')
    end
  end

  describe '.for_queue' do
    it 'generates PascalCase Queue logical ID with Queue suffix' do
      expect(described_class.for_queue(:nightly_dlq)).to eq('NightlyDlqQueue')
      expect(described_class.for_queue('orders')).to eq('OrdersQueue')
    end

    it 'does not duplicate suffix when name already ends with Queue' do
      expect(described_class.for_queue('orders_queue')).to eq('OrdersQueue')
      expect(described_class.for_queue('OrdersQueue')).to eq('OrdersQueue')
    end

    it 'falls back to Queue when input is empty' do
      expect(described_class.for_queue('')).to eq('Queue')
      expect(described_class.for_queue(nil)).to eq('Queue')
    end
  end

  describe '.for_log_group' do
    it 'generates PascalCase LogGroup logical ID based on function logical ID' do
      expect(described_class.for_log_group(:convert)).to eq('ConvertFunctionLogGroup')
      expect(described_class.for_log_group('worker_task')).to eq('WorkerTaskFunctionLogGroup')
    end

    it 'preserves existing LogGroup logical ID' do
      expect(described_class.for_log_group('ConvertFunctionLogGroup')).to eq('ConvertFunctionLogGroup')
    end
  end

  describe '.for_lambda_role and .for_scheduler_role' do
    it 'generates Role logical IDs for functions and schedules' do
      expect(described_class.for_lambda_role(:convert)).to eq('ConvertFunctionRole')
      expect(described_class.for_scheduler_role(:nightly)).to eq('NightlyScheduleRole')
    end

    it 'supports generic .for_role dispatch' do
      expect(described_class.for_role(:convert, type: :lambda)).to eq('ConvertFunctionRole')
      expect(described_class.for_role(:nightly, type: :scheduler)).to eq('NightlyScheduleRole')
    end
  end

  describe '.for generic dispatcher' do
    it 'routes to type-specific methods correctly' do
      expect(described_class.for(:convert, type: :function)).to eq('ConvertFunction')
      expect(described_class.for(:runtime_gems, type: :layer)).to eq('RuntimeGemsLayer')
      expect(described_class.for(:runtime_gems, type: :layer_version)).to eq('RuntimeGemsLayerVersion')
      expect(described_class.for(:nightly, type: :schedule)).to eq('NightlySchedule')
      expect(described_class.for(:batch_dlq, type: :queue)).to eq('BatchDlqQueue')
      expect(described_class.for(:convert, type: :log_group)).to eq('ConvertFunctionLogGroup')
      expect(described_class.for(:convert, type: :role)).to eq('ConvertFunctionRole')
      expect(described_class.for(:nightly, type: :scheduler_role)).to eq('NightlyScheduleRole')
    end

    it 'handles custom types with custom suffix' do
      expect(described_class.for(:my_data, type: :bucket)).to eq('MyDataBucket')
      expect(described_class.for(:my_data_bucket, type: :bucket)).to eq('MyDataBucket')
      expect(described_class.for(:my_bucket_bucket, type: :bucket)).to eq('MyBucketBucket')
    end
  end

  describe 'Determinism & Stability' do
    it 'produces identical logical IDs across repeated invocations' do
      100.times do
        expect(described_class.for_function(:convert)).to eq('ConvertFunction')
        expect(described_class.for_layer(:runtime_gems)).to eq('RuntimeGemsLayer')
        expect(described_class.for_schedule(:nightly)).to eq('NightlySchedule')
      end
    end
  end

  describe 'Property-based Uniqueness Testing' do
    it 'guarantees unique logical IDs for distinct symbolic names in the canonical namespace' do
      prefixes = %w[user order payment invoice doc report notification auth catalog webhook]
      actions = %w[sync process convert export import validate clean notify handle parse]
      suffixes = %w[task worker handler job runner service step stage v1 v2]

      generated_names = []
      prefixes.each do |p|
        actions.each do |a|
          suffixes.each do |s|
            generated_names << "#{p}_#{a}_#{s}"
          end
        end
      end

      expect(generated_names.size).to eq(1000)

      function_ids = generated_names.map { |n| described_class.for_function(n) }
      expect(function_ids.uniq.size).to eq(1000)
      expect(function_ids.all? { |id| id =~ /\A[A-Z][a-zA-Z0-9]*Function\z/ }).to be true

      layer_ids = generated_names.map { |n| described_class.for_layer(n) }
      expect(layer_ids.uniq.size).to eq(1000)
      expect(layer_ids.all? { |id| id =~ /\A[A-Z][a-zA-Z0-9]*Layer\z/ }).to be true

      schedule_ids = generated_names.map { |n| described_class.for_schedule(n) }
      expect(schedule_ids.uniq.size).to eq(1000)
      expect(schedule_ids.all? { |id| id =~ /\A[A-Z][a-zA-Z0-9]*Schedule\z/ }).to be true
    end

    it 'ensures different resource types generate distinct logical IDs for the same symbolic name' do
      sample_names = %i[convert sync worker processor exporter runner]

      sample_names.each do |name|
        ids = [
          described_class.for_function(name),
          described_class.for_layer(name),
          described_class.for_schedule(name),
          described_class.for_queue(name),
          described_class.for_log_group(name)
        ]

        expect(ids.uniq.size).to eq(ids.size)
      end
    end
  end

  describe 'standalone loading' do
    it 'allows individual compiler files to be loaded independently' do
      expect do
        require 'veltrunode/compiler/cloudformation/function_compiler'
        require 'veltrunode/compiler/cloudformation/layer_version_compiler'
        require 'veltrunode/compiler/cloudformation/schedule_compiler'
        require 'veltrunode/compiler/cloudformation/queue_compiler'
        require 'veltrunode/compiler/cloudformation/log_group_compiler'
        require 'veltrunode/compiler/cloudformation/role_compiler'
        require 'veltrunode/compiler/cloudformation'

        cf = Veltrunode::Compiler::CloudFormation
        expect(cf::FunctionCompiler.logical_id_for(:worker)).to eq('WorkerFunction')
        expect(cf::LayerVersionCompiler.logical_id_for(:runtime_gems)).to eq('RuntimeGemsLayerVersion')
        expect(cf::ScheduleCompiler.logical_id_for(:nightly)).to eq('NightlySchedule')
        expect(cf::QueueCompiler.logical_id_for(:dlq)).to eq('DlqQueue')
      end.not_to raise_error
    end
  end
end
