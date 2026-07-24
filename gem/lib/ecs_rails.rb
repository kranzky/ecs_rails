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
# Replaces one-table-per-model with one-table-per-component. An {EcsRails::Entity}
# is a lightweight identity row; all state and behaviour live in small, reusable
# {EcsRails::Component}s composed onto it.
#
# The gem is published as **`ecs_on_rails`**, but the require path and module are
# `ecs_rails` / `EcsRails` — see the README for why.
#
# @example Composing an entity from components
#   class User < ApplicationEntity
#     component Name
#     component Email
#     component Moderator        # a marker: no data, presence is the meaning
#   end
#
#   user = User.create!          # one row in `entities`, no component rows
#   user.email                   # => #<Email> — virtual, not persisted
#   user.email.address = "a@b.com"
#   user.save!                   # now `emails` gets a row
#
# @see EcsRails::Entity     Identity, and the class-level DSL entry point
# @see EcsRails::Component  The ActiveRecord model a component is
# @see EcsRails::DSL        `component` — composition
# @see EcsRails::Relationships `relates_to` — cross-entity links
# @see EcsRails::Querying   `with_component` / `without_component`
# @see EcsRails::Preloading `includes_components`
# @see EcsRails::Presence::Entity `add` / `has?` / `remove`
# @see https://github.com/kranzky/ecs_rails/blob/main/docs/architecture.md
#   architecture.md — the invariants this library guarantees
module EcsRails
  class << self
    # The process-wide component registry, populated by the {EcsRails::DSL#component}
    # DSL at class-load time.
    #
    # Keyed by class *name* rather than class object, so it survives Rails
    # reloading (RFC-0002).
    #
    # @return [EcsRails::Registry] the singleton registry
    # @see EcsRails::Registry
    def registry
      @registry ||= Registry.new
    end

    # The process-wide generator configuration (ADR-0010). Layout only — the
    # runtime does not consult it; the generators and the initializer they emit
    # do.
    #
    # @return [EcsRails::Config] the singleton configuration
    # @see #configure
    def config
      @config ||= Config.new
    end

    # Yields the config for block-style setup, as a host app's
    # `config/initializers/ecs_rails.rb` does.
    #
    # @example Restoring the pre-ADR-0010 single-directory layout
    #   EcsRails.configure { |config| config.entities_path = "app/models" }
    #
    # @yieldparam config [EcsRails::Config] the process-wide configuration
    # @return [EcsRails::Config] the configuration, after the block has run
    def configure
      yield config
    end
  end
end

require "ecs_rails/railtie" if defined?(Rails::Railtie)
