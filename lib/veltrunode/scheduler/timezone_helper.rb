# frozen_string_literal: true

require 'time'
begin
  require 'tzinfo'
rescue LoadError
  # tzinfo not available
end
require_relative 'errors'

module Veltrunode
  module Scheduler
    # タイムゾーン解決およびDST遷移対応の日時変換ヘルパー
    module TimezoneHelper
      class << self
        # IANA タイムゾーン識別子を解決して TZInfo::Timezone を取得します
        #
        # @param timezone_name [String] IANA タイムゾーン識別子 (例: 'Asia/Tokyo', 'America/New_York')
        # @return [TZInfo::Timezone, String]
        def resolve_timezone(timezone_name)
          tz_str = timezone_name.to_s.strip
          tz_str = 'UTC' if tz_str.empty?

          if defined?(TZInfo::Timezone)
            begin
              TZInfo::Timezone.get(tz_str)
            rescue TZInfo::InvalidTimezoneIdentifier
              raise ScheduleExpressionError.new(
                "Invalid timezone identifier '#{tz_str}'",
                reason: 'unrecognized_timezone'
              )
            end
          else
            tz_str
          end
        end

        # ローカル日時コンポーネントを指定タイムゾーンの Time オブジェクトに変換します
        # DST のスキップ（Spring forward）および重複（Fall back）を自動解決します
        #
        # @param year [Integer]
        # @param month [Integer]
        # @param day [Integer]
        # @param hour [Integer]
        # @param min [Integer]
        # @param sec [Integer]
        # @param timezone [TZInfo::Timezone, String]
        # @return [Time]
        def local_to_time(year, month, day, hour, min, sec, timezone)
          tz = timezone.is_a?(String) ? resolve_timezone(timezone) : timezone

          if tz.respond_to?(:local_time)
            begin
              tz.local_time(year, month, day, hour, min, sec)
            rescue TZInfo::PeriodNotFound
              # スキップされた時間帯（Spring Forward）の場合、DST開始後の最初の有効時刻へシフト
              tz.local_time(year, month, day, hour + 1, min, sec)
            rescue TZInfo::AmbiguousTime
              # 重複した時間帯（Fall Back）の場合、時系列として最初に訪れる夏時間を採用
              begin
                tz.local_time(year, month, day, hour, min, sec, 0, true)
              rescue StandardError
                tz.local_time(year, month, day, hour, min, sec, 0, false)
              end
            end
          else
            with_env_tz(timezone.to_s) do
              Time.local(year, month, day, hour, min, sec)
            end
          end
        end

        # 指定された Time オブジェクトを、指定タイムゾーンにおける日時に変換します
        #
        # @param time [Time]
        # @param timezone [TZInfo::Timezone, String]
        # @return [Time]
        def time_in_zone(time, timezone)
          tz = timezone.is_a?(String) ? resolve_timezone(timezone) : timezone

          if tz.respond_to?(:to_local)
            tz.to_local(time)
          else
            with_env_tz(timezone.to_s) do
              Time.at(time.to_f)
            end
          end
        end

        def with_env_tz(tz)
          MUTEX.synchronize do
            orig = ENV.fetch('TZ', nil)
            ENV['TZ'] = tz
            yield
          ensure
            if orig
              ENV['TZ'] = orig
            else
              ENV.delete('TZ')
            end
          end
        end
      end

      MUTEX = Mutex.new
      private_constant :MUTEX
    end
  end
end
