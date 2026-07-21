# frozen_string_literal: true

require "active_record"
require "active_support"

require "ecs_rails/version"
require "ecs_rails/config"
require "ecs_rails/errors"
require "ecs_rails/registry"
require "ecs_rails/lazy"
require "ecs_rails/presence"
require "ecs_rails/validations"
require "ecs_rails/dsl"
require "ecs_rails/relationships"
require "ecs_rails/querying"
require "ecs_rails/preloading"
require "ecs_rails/entity"
require "ecs_rails/component"

# ECS Rails — an Entity-Component-System reimagining of ActiveRecord.
#
# See docs/architecture.md for the invariants this library guarantees.
module EcsRails
  class << self
    # The process-wide component registry. See RFC-0002.
    def registry
      @registry ||= Registry.new
    end

    # The process-wide generator configuration (ADR-0010). Layout only — the
    # runtime does not consult it; the generators and the initializer they emit
    # do.
    def config
      @config ||= Config.new
    end

    # Yields the config for block-style setup, as a host app's
    # config/initializers/ecs_rails.rb does:
    #
    #   EcsRails.configure { |config| config.entities_path = "app/models" }
    def configure
      yield config
    end
  end
end

require "ecs_rails/railtie" if defined?(Rails::Railtie)
