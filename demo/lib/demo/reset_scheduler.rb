# frozen_string_literal: true

module Demo
  # Resets the demo database on a fixed wall-clock cadence, and exposes the next
  # reset time so the UI countdown stays exactly in sync (both read
  # #next_reset_at). Started from config/puma.rb on web-server boot, so it never
  # runs in dev/test or one-off rake/console processes.
  #
  # A PostgreSQL advisory lock guards the reset, so if the app ever runs on more
  # than one machine only one performs it. (Truncate-then-seed is idempotent
  # anyway, so a rare double is harmless.)
  class ResetScheduler
    ADVISORY_LOCK_KEY = 8_250_001

    class << self
      def enabled?
        ENV["DEMO_RESET_ENABLED"] == "true"
      end

      def interval_seconds
        [ENV.fetch("DEMO_RESET_INTERVAL_MINUTES", "60").to_i, 1].max * 60
      end

      # The next boundary aligned to the interval from the Unix epoch — a pure
      # function of the clock, so no state needs persisting and the countdown
      # can compute the same value the scheduler sleeps until.
      def next_reset_at(now = Time.now)
        period = interval_seconds
        Time.at((now.to_i / period + 1) * period).utc
      end

      def start
        return unless enabled?

        Thread.new { new.run }
      end
    end

    def run
      Rails.logger.info("[demo-reset] scheduler up; interval #{self.class.interval_seconds}s")
      loop do
        pause = self.class.next_reset_at - Time.now
        sleep(pause) if pause.positive?
        perform
      end
    rescue => e
      Rails.logger.error("[demo-reset] scheduler stopped: #{e.class}: #{e.message}")
    end

    def perform
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        return unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")

        begin
          Demo::Reset.call
          Rails.logger.info("[demo-reset] database reset at #{Time.now.utc.iso8601}")
        ensure
          conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
        end
      end
    rescue => e
      Rails.logger.error("[demo-reset] reset failed: #{e.class}: #{e.message}")
    end
  end
end
