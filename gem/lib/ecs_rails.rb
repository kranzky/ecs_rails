# frozen_string_literal: true

require "active_record"
require "active_support"

require "ecs_rails/version"
require "ecs_rails/errors"
require "ecs_rails/registry"
require "ecs_rails/lazy"
require "ecs_rails/dsl"
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
  end
end

require "ecs_rails/railtie" if defined?(Rails::Railtie)
