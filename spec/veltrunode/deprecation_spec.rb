# frozen_string_literal: true

require 'spec_helper'
require 'veltrunode/deprecation'
require 'veltrunode/dsl/base_builder'

RSpec.describe Veltrunode::Deprecation do
  before do
    described_class.reset!
  end

  after do
    described_class.reset!
  end

  describe '.deprecate' do
    let(:test_class) do
      Class.new do
        def existing_feature(arg)
          "result: #{arg}"
        end

        def new_feature(arg)
          "new result: #{arg}"
        end
      end
    end

    it 'registers the deprecated method in registry and deprecated_methods list' do
      entry = described_class.deprecate(
        test_class,
        :existing_feature,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0',
        alternative: :new_feature
      )

      expect(entry.target).to eq(test_class)
      expect(entry.method_name).to eq(:existing_feature)
      expect(entry.deprecated_since).to eq('0.1.45')
      expect(entry.removal_version).to eq('0.2.0')
      expect(entry.alternative).to eq('new_feature')
      expect(described_class.deprecated_methods).to include(entry)
      expect(entry.to_h).to eq(
        target: test_class,
        method_name: :existing_feature,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0',
        alternative: 'new_feature'
      )
    end

    it 'outputs deprecation warning with deprecated_since and removal_version when calling wrapped method' do
      described_class.deprecate(
        test_class,
        :existing_feature,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0',
        alternative: :new_feature
      )

      instance = test_class.new
      expect do
        res = instance.existing_feature('test')
        expect(res).to eq('result: test')
      end.to output(
        /\[DEPRECATION WARNING\].*`existing_feature` is deprecated since version 0\.1\.45/
      ).to_stderr
    end

    it 'delegates to alternative method when deprecated method was not previously defined' do
      described_class.deprecate(
        test_class,
        :legacy_alias,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0',
        alternative: :new_feature
      )

      instance = test_class.new
      expect do
        res = instance.legacy_alias('hello')
        expect(res).to eq('new result: hello')
      end.to output(
        /\[DEPRECATION WARNING\].*`legacy_alias` is deprecated since version 0\.1\.45/
      ).to_stderr
    end

    it 'suppresses duplicate warnings for the same message' do
      described_class.deprecate(
        test_class,
        :existing_feature,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0'
      )

      instance = test_class.new
      described_class.output = StringIO.new

      instance.existing_feature('1')
      instance.existing_feature('2')

      output_str = described_class.output.string
      occurrences = output_str.scan('[DEPRECATION WARNING]').size
      expect(occurrences).to eq(1)
    end
  end

  describe 'VELTRUNODE_DEPRECATION=error environment variable' do
    let(:test_class) do
      Class.new do
        def old_task
          :ok
        end
      end
    end

    around do |example|
      orig_env = ENV.fetch('VELTRUNODE_DEPRECATION', nil)
      example.run
    ensure
      if orig_env
        ENV['VELTRUNODE_DEPRECATION'] = orig_env
      else
        ENV.delete('VELTRUNODE_DEPRECATION')
      end
    end

    it 'raises DeprecationError when VELTRUNODE_DEPRECATION=error' do
      ENV['VELTRUNODE_DEPRECATION'] = 'error'

      described_class.deprecate(
        test_class,
        :old_task,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0',
        alternative: :new_task
      )

      instance = test_class.new
      expect do
        instance.old_task
      end.to raise_error(
        Veltrunode::DeprecationError,
        /`old_task` is deprecated since version 0\.1\.45 and will be removed in version 0\.2\.0/
      )
    end

    it 'raises DeprecationError when behavior is set to :error programmatically' do
      described_class.behavior = :error

      described_class.deprecate(
        test_class,
        :old_task,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0'
      )

      instance = test_class.new
      expect do
        instance.old_task
      end.to raise_error(Veltrunode::Deprecation::DeprecationError)
    end
  end

  describe 'DSL BaseBuilder integration' do
    let(:sample_builder) do
      Class.new(Veltrunode::DSL::BaseBuilder) do
        deprecate :legacy_setting, deprecated_since: '0.1.45', removal_version: '0.2.0', alternative: :current_setting

        attr_reader :value

        def current_setting(val)
          @value = val
        end
      end
    end

    it 'allows deprecate helper on builder classes and warns during DSL execution' do
      builder = sample_builder.new
      expect do
        builder.legacy_setting('my-value')
      end.to output(/\[DEPRECATION WARNING\].*`legacy_setting` is deprecated since version 0\.1\.45/).to_stderr

      expect(builder.value).to eq('my-value')
    end

    it 'raises DeprecationError during DSL evaluation when VELTRUNODE_DEPRECATION=error' do
      builder = sample_builder.new
      described_class.behavior = :error

      expect do
        builder.legacy_setting('my-value')
      end.to raise_error(Veltrunode::DeprecationError)
    end
  end

  describe '.warn' do
    it 'emits warning with given details' do
      expect do
        described_class.warn(
          'my_custom_dsl_method',
          deprecated_since: '0.1.40',
          removal_version: '0.2.0',
          alternative: 'new_dsl_method'
        )
      end.to output(
        /\[DEPRECATION WARNING\] `my_custom_dsl_method` is deprecated since version 0\.1\.40/
      ).to_stderr
    end
  end

  describe 'arguments, kwargs and block forwarding' do
    let(:test_class) do
      Class.new do
        def calculate(a, b, multiplier: 1)
          res = (a + b) * multiplier
          block_given? ? yield(res) : res
        end
      end
    end

    it 'forwards positional arguments, keyword arguments, and blocks correctly' do
      described_class.deprecate(
        test_class,
        :calculate,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0'
      )

      instance = test_class.new
      result = nil
      expect do
        result = instance.calculate(2, 3, multiplier: 4) { |val| val * 10 }
      end.to output(/\[DEPRECATION WARNING\]/).to_stderr

      expect(result).to eq(200)
    end
  end

  describe 'error mode case-insensitivity and defaults' do
    around do |example|
      orig_env = ENV.fetch('VELTRUNODE_DEPRECATION', nil)
      example.run
    ensure
      if orig_env
        ENV['VELTRUNODE_DEPRECATION'] = orig_env
      else
        ENV.delete('VELTRUNODE_DEPRECATION')
      end
    end

    it 'handles case-insensitive ERROR and whitespace in environment variable' do
      ENV['VELTRUNODE_DEPRECATION'] = '  ERROR  '
      expect(described_class.error_mode?).to be true
    end

    it 'does not enter error mode for other values like warn or empty' do
      ENV['VELTRUNODE_DEPRECATION'] = 'warn'
      expect(described_class.error_mode?).to be false

      ENV['VELTRUNODE_DEPRECATION'] = ''
      expect(described_class.error_mode?).to be false
    end
  end

  describe 'integration with Veltrunode.application DSL' do
    around do |example|
      orig_env = ENV.fetch('VELTRUNODE_DEPRECATION', nil)
      example.run
    ensure
      if orig_env
        ENV['VELTRUNODE_DEPRECATION'] = orig_env
      else
        ENV.delete('VELTRUNODE_DEPRECATION')
      end
    end

    it 'warns when calling a deprecated method inside Veltrunode.application block' do
      Veltrunode::DSL::ApplicationBuilder.deprecate(
        :legacy_opt,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0'
      )

      expect do
        Veltrunode.application 'test-app' do
          legacy_opt
        end
      end.to output(/\[DEPRECATION WARNING\].*legacy_opt` is deprecated since version 0\.1\.45/).to_stderr
    end

    it 'raises DeprecationError on deprecated method with VELTRUNODE_DEPRECATION=error' do
      ENV['VELTRUNODE_DEPRECATION'] = 'error'

      Veltrunode::DSL::ApplicationBuilder.deprecate(
        :legacy_opt,
        deprecated_since: '0.1.45',
        removal_version: '0.2.0'
      )

      expect do
        Veltrunode.application 'test-app' do
          legacy_opt
        end
      end.to raise_error(Veltrunode::DeprecationError, /legacy_opt` is deprecated since version 0\.1\.45/)
    end
  end
end
