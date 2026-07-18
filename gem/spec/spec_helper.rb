# frozen_string_literal: true

require "bundler/setup"
require "active_record"
require "ecs_rails"

# Connect to the test database. Override with DATABASE_URL if needed.
ActiveRecord::Base.establish_connection(
  ENV.fetch("DATABASE_URL", "postgresql:///ecs_rails_test")
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
  #
  # joinable: false is load-bearing, not decoration — it is what Rails' own
  # use_transactional_tests sets, for the reason RFC-0006 ran into. Without it,
  # a transaction opened *inside* an example (every ActiveRecord save opens one)
  # merges into this one instead of taking a savepoint, and a rollback inside it
  # is then silently swallowed: the rows survive. Any example asserting that a
  # failed save rolls back would pass whether the code rolled back or not.
  #
  # Marking this one non-joinable makes save's transaction a real savepoint, so
  # rollback is observable and the atomicity RFC-0006 promises is actually
  # tested. See "atomicity" in spec/lazy_spec.rb.
  config.around do |example|
    ActiveRecord::Base.transaction(joinable: false) do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
