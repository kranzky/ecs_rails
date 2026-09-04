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
require_relative "../catalogue_options"

module EcsRails
  # The Rails generators (RFC-0008): `ecs_rails:install`, `ecs_rails:component`
  # and `ecs_rails:upgrade`. (`ecs_rails:relationship` was removed by ADR-0017:
  # a relationship needs no table of its own.)
  #
  # They read {EcsRails.config} to place their files (ADR-0010). The gem runtime
  # never consults that config — only these do.
  module Generators
    # `rails g ecs_rails:install`
    #
    # Implements RFC-0008 and ADR-0018. Emits the install migration — the
    # `entities` table plus one table per catalogue component in the selected
    # sets, each rendered from the gem's schema declarations — the two abstract
    # base classes a host app subclasses from, and one one-line class per
    # catalogue component. After `db:migrate`, an application builds from the
    # catalogue with no further migration.
    #
    #   rails g ecs_rails:install                         # the core set
    #   rails g ecs_rails:install --sets core commerce    # more of the shelf
    #   rails g ecs_rails:install --rename money:Price    # the collision remedy
    #
    # Inherits from Base rather than NamedBase: install takes no NAME argument.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      include CatalogueOptions

      source_root File.expand_path("templates", __dir__)

      desc "Creates the install migration (entities + every catalogue table in the " \
           "chosen sets), the ApplicationEntity / ApplicationComponent base classes, " \
           "and a one-line class per catalogue component."

      # Emits the install migration.
      #
      # A Thor task: invoked as a generator step, not called directly.
      #
      # @return [void]
      def create_migration_file
        migration_template(
          "install_migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_install.rb")
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

      # ADR-0018: one one-line class per catalogue component in the selected
      # sets. The application owns the constant (renamed with --rename where it
      # collides); the behaviour and the table are the gem's concern.
      def create_catalogue_classes
        create_catalogue_class_files(catalogue_components)
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
