# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A WGS 84 coordinate, and when it was geocoded. Derived data: it exists to
    # be filled by an entity-blind geocoding system, paired to an `Address` by
    # sharing its slot (`component Address, prefix: :registered` +
    # `component Geolocation, prefix: :registered`).
    module Geolocation
      extend Definition

      table "geolocations"
      schema do |t|
        t.decimal  :lat,         default: nil, precision: 10, scale: 7
        t.decimal  :lng,         default: nil, precision: 10, scale: 7
        t.datetime :geocoded_at, default: nil
      end

      included do
        validates :lat, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
        validates :lng, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
      end

      # @return [Boolean] whether a coordinate has been set
      def geocoded?
        lat.present? && lng.present?
      end

      # @return [Array<BigDecimal>, nil] `[lat, lng]`, or nil when not geocoded
      def coordinates
        [lat, lng] if geocoded?
      end

      # Records a lookup's answer: sets the coordinate and stamps `geocoded_at`.
      # A lookup that found nothing is recorded as `locate(nil, nil)` — the
      # stamp still says the address was tried, so a system need not retry it
      # until the address changes, and stale coordinates never outlive it.
      #
      # `at:` defaults to now. A geocoding system that decides staleness by
      # comparing `geocoded_at` with the address's `updated_at` should pass
      # the `updated_at` it read instead: an edit landing while the lookup runs
      # is then still newer than the stamp, and the next run recomputes it.
      #
      # @param lat [Numeric, nil]
      # @param lng [Numeric, nil]
      # @param at [Time] the moment (or address version) the answer describes
      # @return [void]
      def locate(lat, lng, at: Time.current)
        assign_attributes(lat: lat, lng: lng, geocoded_at: at)
      end
    end
  end
end
