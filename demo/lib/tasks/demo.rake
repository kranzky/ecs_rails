# frozen_string_literal: true

namespace :demo do
  desc "Wipe all data and reload the demo seed"
  task reset: :environment do
    summary = Demo::Reset.call
    puts "Demo database reset: #{summary}."
  end

  desc "Geocode new and changed addresses (simulated lookups)"
  task geocode: :environment do
    puts "The geocoder wrote #{Demo::Geocoder.call} Geolocation(s)."
  end
end
