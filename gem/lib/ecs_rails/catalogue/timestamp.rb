# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A point in time: issued_at, published_at, last_seen_at — one slot each.
    module Timestamp
      extend Definition

      table "timestamps"
      primary_attribute :at
      schema do |t|
        t.datetime :at, default: nil
      end

      # Sets `at` to now and saves.
      #
      # @return [Time]
      def stamp!
        update!(at: Time.current)
        at
      end

      # @return [Boolean] whether `at` is set and in the past
      def past?
        at.present? && at <= Time.current
      end

      # @return [Boolean] whether `at` is set and in the future
      def future?
        at.present? && at > Time.current
      end
    end
  end
end
