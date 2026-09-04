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

      # Sets the coordinate and stamps `geocoded_at`.
      #
      # @param lat [Numeric]
      # @param lng [Numeric]
      # @return [void]
      def locate(lat, lng)
        assign_attributes(lat: lat, lng: lng, geocoded_at: Time.current)
      end
    end
  end
end
