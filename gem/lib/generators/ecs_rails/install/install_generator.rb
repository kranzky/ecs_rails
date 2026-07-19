# frozen_string_literal: true

# active_record must be required explicitly: rails/generators/active_record/
# migration references ActiveRecord::Migration and ActiveRecord::VERSION but
# does not load them itself. A host Rails app happens to have ActiveRecord
# loaded already, so omitting this only breaks in isolation — which is exactly
# where it is hardest to notice.
require "active_record"
require "rails/generators/named_base"
require "rails/generators/active_record/migration"

# ADR-0010: the generator reads EcsRails.config to place its files and to fill in
# the initializer. Require the library explicitly so the generator stands on its
# own requires — a clean `rails g` process must reach EcsRails.config without
# depending on some other file having loaded it first (see RFC-0008's isolation
# note and spec/generators/generator_isolation_spec.rb).
require "ecs_rails"

module EcsRails
  module Generators
    # `rails g ecs_rails:install`
    #
    # Implements RFC-0008. Emits the `entities` migration and the two abstract
    # base classes a host app subclasses from. The migration mirrors
    # docs/architecture.md §2 exactly — if the two ever disagree, the
    # architecture document wins.
    #
    # Inherits from Base rather than NamedBase: install takes no NAME argument.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the entities migration and the ApplicationEntity / " \
           "ApplicationComponent base classes."

      def create_migration_file
        migration_template(
          "migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_create_entities.rb")
        )
      end

      # ADR-0010: base classes land under the configured layout —
      # ApplicationEntity at entities_path, ApplicationComponent at
      # components_path (entities_path/components).
      def create_base_models
        template "application_entity.rb.tt",
                 File.join(EcsRails.config.entities_path, "application_entity.rb")
        template "application_component.rb.tt",
                 File.join(EcsRails.config.components_path, "application_component.rb")
      end

      # ADR-0010: the generated initializer both records the chosen layout (so
      # ecs_rails:component and the app agree on it) and collapses the nested
      # components directory, so Zeitwerk maps app/entities/components/name.rb to
      # the top-level `Name` rather than `Components::Name`.
      #
      # An initializer — not application.rb, not the gem's Railtie — is the right
      # home for the collapse: it runs before eager_load under both lazy and
      # eager modes, and it does not read entities_path before app initializers
      # have had their chance to set it. See ADR-0010 "How it works".
      def create_initializer
        template "initializer.rb.tt", "config/initializers/ecs_rails.rb"
      end

      private

      # The literal path written into the generated initializer's
      # `entities_path =` line. Reflects whatever entities_path is at generation
      # time, so a pre-configured layout carries through into the initializer.
      def entities_path
        EcsRails.config.entities_path
      end

      # The `ActiveRecord::Migration[x.y]` version stamp, tracking whatever
      # ActiveRecord the host app is actually running.
      def migration_version
        "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
