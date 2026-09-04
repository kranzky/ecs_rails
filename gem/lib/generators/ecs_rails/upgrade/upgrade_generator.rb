# frozen_string_literal: true

# See the note in install_generator.rb: rails/generators/active_record/migration
# references ActiveRecord::Migration without loading it.
require "active_record"
require "rails/generators/base"
require "rails/generators/active_record/migration"

# Stands on its own requires, like the other generators (RFC-0008's isolation
# note and spec/generators/generator_isolation_spec.rb).
require "ecs_rails"

module EcsRails
  module Generators
    # `rails g ecs_rails:upgrade`
    #
    # Brings an existing application's component tables up to the gem's current
    # schema, in one migration. ADR-0018 makes this the *only* migration a user
    # ever runs after `ecs_rails:install`; its first job (RFC-0014 / ADR-0015) is
    # the slot column:
    #
    #   add_column   :emails, :slot, :string, null: false, default: ""
    #   remove_index :emails, column: :entity_id, unique: true
    #   add_index    :emails, [:entity_id, :slot], unique: true
    #
    # for every component table that lacks one. Safe on shipped data: every
    # existing row is the single `slot = ""`, so the new composite index admits
    # exactly the rows the old one did.
    #
    # Component tables are found by inspecting the database, not the registry:
    # a generator runs before the app's classes are loaded, and the registry
    # would miss a component whose entity is never referenced. Any table with an
    # `entity_id` column is a component table (architecture.md §2) — including
    # `relates_to` backing tables, which are components too. When every table is
    # already current, nothing is written and the generator says so.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Upgrades existing component tables to the gem's current schema " \
           "(currently: the slot column and (entity_id, slot) index)."

      # Emits the upgrade migration, or reports there is nothing to do.
      #
      # A Thor task: invoked as a generator step, not called directly.
      #
      # @return [void]
      def create_migration_file
        if tables_missing_slot.empty?
          say "Every component table already has a slot column; nothing to upgrade.", :green
          return
        end

        migration_template(
          "slots_migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_add_slots.rb")
        )
      end

      private

      # Component tables (any table with an entity_id column, other than
      # `entities` itself) that have no `slot` column yet. Sorted, so the
      # migration is deterministic; uniq, because a multi-schema search_path can
      # list one name twice (the columns then resolve to the first schema).
      def tables_missing_slot
        @tables_missing_slot ||= connection.tables.uniq.sort.select do |table|
          next false if table == "entities"

          columns = connection.columns(table).map(&:name)
          columns.include?("entity_id") && !columns.include?("slot")
        end
      end

      def connection
        ActiveRecord::Base.connection
      end

      def migration_version
        "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
