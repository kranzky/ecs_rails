# frozen_string_literal: true

# Delegates to Demo::Seed so the seed data has a single definition shared with
# the periodic reset (Demo::Reset / Demo::ResetScheduler).
summary = Demo::Seed.call
puts "Seeded #{summary}."
