# frozen_string_literal: true

module Veltrunode
  module Deprecation
    # 非推奨メソッドの登録メタデータ
    class DeprecatedMethod
      attr_reader :target, :method_name, :deprecated_since, :removal_version, :alternative

      def initialize(target:, method_name:, deprecated_since:, removal_version:, alternative: nil)
        @target = target
        @method_name = method_name.to_sym
        @deprecated_since = deprecated_since.to_s.strip
        @removal_version = removal_version.to_s.strip
        @alternative = alternative&.to_s&.strip
        freeze
      end

      # 警告メッセージを生成します
      #
      # @param caller_location [Thread::Backtrace::Location, String, nil] 呼び出し元の場所
      # @return [String]
      def message(caller_location: nil)
        target_name = if @target.respond_to?(:name) && @target.name && !@target.name.empty?
                        "#{@target.name}#"
                      else
                        ''
                      end

        msg = "[DEPRECATION WARNING] `#{target_name}#{@method_name}` is deprecated " \
              "since version #{@deprecated_since} and will be removed in version #{@removal_version}."

        msg += " Please use `#{@alternative}` instead." if @alternative && !@alternative.empty?
        msg += " (called from #{caller_location})" if caller_location
        msg
      end

      def to_h
        {
          target: @target,
          method_name: @method_name,
          deprecated_since: @deprecated_since,
          removal_version: @removal_version,
          alternative: @alternative
        }
      end
    end
  end
end
