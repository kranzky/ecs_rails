# frozen_string_literal: true

require "digest"

module Demo
  # Geocoding, simulated: a short list of city centres and no network, keys or
  # rate limits. It stands in for a real geocoding service the way
  # PaymentGateway stands in for a card processor, so every coordinate it
  # returns is invented. A known city's centre is nudged by an amount derived
  # from the whole address, so two streets in one city get two points and the
  # same address always gets the same one. Anything else is "not found".
  module Gazetteer
    # Approximate city centres, keyed by ISO country code, then locality.
    PLACES = {
      "AU" => { "perth" => [-31.9523, 115.8613], "sydney" => [-33.8688, 151.2093],
                "melbourne" => [-37.8136, 144.9631], "brisbane" => [-27.4698, 153.0251],
                "adelaide" => [-34.9285, 138.6007] },
      "CA" => { "toronto" => [43.6532, -79.3832] },
      "DE" => { "berlin" => [52.5200, 13.4050] },
      "FR" => { "paris" => [48.8566, 2.3522] },
      "GB" => { "london" => [51.5074, -0.1278], "cambridge" => [52.2053, 0.1218],
                "manchester" => [53.4808, -2.2426], "wilmslow" => [53.3280, -2.2310],
                "edinburgh" => [55.9533, -3.1883] },
      "IE" => { "dublin" => [53.3498, -6.2603] },
      "JP" => { "tokyo" => [35.6762, 139.6503] },
      "NZ" => { "auckland" => [-36.8485, 174.7633], "wellington" => [-41.2865, 174.7762] },
      "SG" => { "singapore" => [1.3521, 103.8198] },
      "US" => { "new york" => [40.7128, -74.0060], "arlington" => [38.8816, -77.0910],
                "washington" => [38.9072, -77.0369], "boston" => [42.3601, -71.0589],
                "san francisco" => [37.7749, -122.4194], "seattle" => [47.6062, -122.3321] }
    }.freeze

    # The largest nudge in degrees: about a kilometre, so a point stays in town.
    NUDGE = 0.01

    module_function

    # Looks an address up by country and locality.
    #
    # @param address [Address]
    # @return [Array(Float, Float), nil] `[lat, lng]`, or nil when the place is unknown
    def lookup(address)
      centre = PLACES.dig(address.country.to_s.upcase, address.locality.to_s.squish.downcase)
      return if centre.nil?

      north, east = nudges_for(address)
      [(centre[0] + north).round(7), (centre[1] + east).round(7)]
    end

    # Two numbers in -NUDGE..NUDGE, fixed for an address's fields regardless
    # of their case and spacing.
    def nudges_for(address)
      fields = [address.line1, address.line2, address.locality, address.region, address.postcode, address.country]
      text = fields.map { |field| field.to_s.squish.downcase }.join("|")
      Digest::SHA256.digest(text).unpack("NN").map { |n| (n.fdiv(0xFFFF_FFFF) * 2 - 1) * NUDGE }
    end
    private_class_method :nudges_for
  end
end
