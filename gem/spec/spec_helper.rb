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

# The declarations support/models.rb made at load time. EcsRails.registry is a
# process-wide singleton, and some specs `clear!` it to test in isolation — which
# would wipe these for every example that ran afterwards, in any file, making the
# suite order-dependent. This was a real, recurring landmine (registry_spec, and
# twice during RFC implementation). Restoring this baseline after every example
# seals it centrally, so no spec can leak a cleared registry to the next.
ECS_RAILS_REGISTRY_BASELINE = EcsRails.registry.snapshot.freeze

# EcsRails.config (ADR-0010) is a process-wide singleton, exactly like the
# registry. The generator specs — and the config spec — mutate entities_path to
# prove the escape hatch and the derived components_path, which would leak the
# changed layout into every example that ran afterwards and make the suite
# order-dependent. Restoring the pristine default after every example seals it
# centrally, the same way the registry baseline above does.
ECS_RAILS_CONFIG_DEFAULT_ENTITIES_PATH = EcsRails.config.entities_path.dup.freeze

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.after { EcsRails.registry.restore(ECS_RAILS_REGISTRY_BASELINE) }
  config.after { EcsRails.config.entities_path = ECS_RAILS_CONFIG_DEFAULT_ENTITIES_PATH.dup }

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
