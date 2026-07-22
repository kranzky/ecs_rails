# frozen_string_literal: true

namespace :demo do
  desc "Wipe all data and reload the demo seed"
  task reset: :environment do
    summary = Demo::Reset.call
    puts "Demo database reset: #{summary}."
  end
end
