# frozen_string_literal: true

require "bundler/setup"
require "active_record"
require "rorecs"

# Connect to the test database. Override with DATABASE_URL if needed.
ActiveRecord::Base.establish_connection(
  ENV.fetch("DATABASE_URL", "postgresql:///rorecs_test")
)

# Keep the test output readable — we assert on queries, not on logs.
ActiveRecord::Base.logger = nil

require_relative "support/schema"
require_relative "support/models"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Every example runs in a transaction that is rolled back afterwards.
  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
