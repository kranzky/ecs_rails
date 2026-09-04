# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A span of time: an event, a booking, an availability window. `ends_at`
    # may be nil for an open-ended period.
    module Period
      extend Definition

      table "periods"
      schema do |t|
        t.datetime :starts_at, default: nil
        t.datetime :ends_at,   default: nil
        t.string   :time_zone, default: nil
        t.boolean  :all_day,   default: false, null: false
      end

      included do
        validate :ecs_ends_after_starts
      end

      # @return [Boolean] whether now falls inside the period
      def current?(at = Time.current)
        return false if starts_at.nil?

        at >= starts_at && (ends_at.nil? || at < ends_at)
      end

      # @param other [Period, Range<Time>]
      # @return [Boolean] whether the two periods share any instant
      def overlaps?(other)
        other_start, other_end = other.respond_to?(:starts_at) ? [other.starts_at, other.ends_at] : [other.begin, other.end]
        return false if starts_at.nil? || other_start.nil?

        (ends_at.nil? || other_start < ends_at) && (other_end.nil? || starts_at < other_end)
      end

      # @return [ActiveSupport::Duration, nil] the length to the second, or nil
      #   when open-ended
      def duration
        (ends_at - starts_at).round.seconds if starts_at && ends_at
      end

      private

      def ecs_ends_after_starts
        return if starts_at.nil? || ends_at.nil? || ends_at >= starts_at

        errors.add(:ends_at, "must not be before starts_at")
      end
    end
  end
end
