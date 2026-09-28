# frozen_string_literal: true

module Veltrunode
  module Deprecation
    # 非推奨メソッドのラッピングを行うクラス
    class MethodWrapper
      class << self
        def wrap(target, entry)
          new(target, entry).wrap
        end
      end

      def initialize(target, entry)
        @target = target
        @entry = entry
      end

      def wrap
        method_sym = @entry.method_name
        has_method = @target.method_defined?(method_sym) || @target.private_method_defined?(method_sym)

        if has_method
          wrap_existing_method(method_sym)
        else
          wrap_new_method(method_sym)
        end
      end

      private

      def wrap_existing_method(method_sym)
        unique_suffix = @entry.deprecated_since.to_s.gsub(/[^a-zA-Z0-9_]/, '_')
        original_method_name = :"_unwrapped_#{method_sym}_#{unique_suffix}"
        entry = @entry

        @target.alias_method(original_method_name, method_sym)

        @target.define_method(method_sym) do |*args, **kwargs, &block|
          loc = caller_locations(1, 1)&.first
          Veltrunode::Deprecation.warn(entry, caller_location: loc)
          if kwargs.empty?
            send(original_method_name, *args, &block)
          else
            send(original_method_name, *args, **kwargs, &block)
          end
        end
      end

      def wrap_new_method(method_sym)
        alt_sym = @entry.alternative&.to_sym
        entry = @entry

        @target.define_method(method_sym) do |*args, **kwargs, &block|
          loc = caller_locations(1, 1)&.first
          Veltrunode::Deprecation.warn(entry, caller_location: loc)
          return unless alt_sym && respond_to?(alt_sym, true)

          if kwargs.empty?
            send(alt_sym, *args, &block)
          else
            send(alt_sym, *args, **kwargs, &block)
          end
        end
      end
    end
  end
end
