# frozen_string_literal: true

# See the note in install_generator.rb: rails/generators/active_record/migration
# references ActiveRecord::Migration without loading it.
require "active_record"
require "rails/generators/base"
require "rails/generators/active_record/migration"

# Stands on its own requires, like the other generators (RFC-0008's isolation
# note and spec/generators/generator_isolation_spec.rb).
require "ecs_rails"
require_relative "../catalogue_options"

module EcsRails
  module Generators
    # `rails g ecs_rails:upgrade`
    #
    # Brings an existing application's schema up to the gem's current one.
    # ADR-0018 makes this the *only* migration a user ever runs after
    # `ecs_rails:install`. It has two jobs today, each its own migration file so
    # that a later gem version can add a third without renaming either:
    #
    # 1. **Slots** (RFC-0014 / ADR-0015) — for every component table without a
    #    `slot` column:
    #
    #      add_column   :emails, :slot, :string, null: false, default: ""
    #      remove_index :emails, column: :entity_id, unique: true
    #      add_index    :emails, [:entity_id, :slot], unique: true
    #
    #    Safe on shipped data: every existing row is the single `slot = ""`, so
    #    the new composite index admits exactly the rows the old one did.
    #
    # 2. **Shared relationships** (ADR-0017) — creates the `relationships` table
    #    if it is missing, and moves every pre-0.3 per-relationship backing table
    #    (`post_authors`, `membership_users`, ...) into it: each row becomes a
    #    row with `slot` = the relationship name, `target_id` = the old
    #    `<name>_id`, `owner_model` = the owner's discriminator; the old table is
    #    then dropped. Irreversible, and written as `up`/`down` to say so.
    #
    # 3. **Shared markers** (ADR-0018 §4) — moves every pre-0.3 marker table (a
    #    component table with no attribute columns at all: `moderators`,
    #    `administrators`) into `markers`, slot = the table's singular name; the
    #    old table is then dropped. Irreversible.
    #
    # Before 2 and 3, **the catalogue** (ADR-0018): for every catalogue
    # component in the selected `--sets` (and every catalogue table that already
    # exists, whatever its set), a missing table is created and a table that
    # predates a column or index is brought forward — both rendered from the
    # gem's schema declarations, the same recordings install renders. Missing
    # one-line classes are written too; existing files are never touched. This
    # is how a newer gem version's catalogue additions, or a set added later,
    # reach an application.
    #
    # Tables are found by inspecting the database, not the registry: a generator
    # runs before the app's classes are loaded, and the registry would miss a
    # component whose entity is never referenced. Any table with an `entity_id`
    # column is a component table (architecture.md §2). A backing table is
    # recognised by its shape — entity_id, exactly one other `<name>_id` uuid
    # column, timestamps, nothing else — and its ADR-0013 name,
    # `<owner>_<names>`. The developer reviews the file before running it, as
    # with any generated migration. When nothing is pending, nothing is written
    # and the generator says so.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      include CatalogueOptions

      source_root File.expand_path("templates", __dir__)

      desc "Upgrades an existing schema to the gem's current one: the slot column " \
           "on component tables, and the shared relationships and markers tables."

      # Emits the slot migration for component tables that lack the column, or
      # says there is nothing to do. Backing tables about to be moved into
      # `relationships`, and marker tables about to be moved into `markers`, are
      # skipped — they are dropped a migration later.
      #
      # A Thor task: invoked as a generator step, not called directly.
      #
      # @return [void]
      def create_slots_migration
        if tables_missing_slot.empty?
          say "Every component table already has a slot column.", :green
          return
        end

        migration_template(
          "slots_migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_add_slots.rb")
        )
      end

      # Emits the catalogue migration — missing tables and missing columns or
      # indexes on existing ones — or says everything is current, and writes any
      # missing one-line classes for the selected sets.
      #
      # A Thor task: invoked as a generator step, not called directly.
      #
      # @return [void]
      def create_catalogue_migration
        create_catalogue_class_files(catalogue_components)

        if catalogue_changes.empty?
          say "Every catalogue table is current.", :green
          return
        end

        migration_template(
          "catalogue_migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_catalogue.rb")
        )
      end

      # Emits the shared-relationships data move when per-relationship backing
      # tables remain, or says so. The `relationships` table itself is the
      # catalogue migration's business, which runs first.
      #
      # A Thor task: invoked as a generator step, not called directly.
      #
      # @return [void]
      def create_relationships_migration
        if backing_tables.empty?
          say "Relationships already live in the shared relationships table.", :green
          return
        end

        migration_template(
          "relationships_migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_shared_relationships.rb")
        )
      end

      # Emits the shared-markers data move when empty per-marker tables remain,
      # or says so. The `markers` table itself is the catalogue migration's
      # business, which runs first.
      #
      # A Thor task: invoked as a generator step, not called directly.
      #
      # @return [void]
      def create_markers_migration
        if marker_tables.empty?
          say "Markers already live in the shared markers table.", :green
          return
        end

        migration_template(
          "markers_migration.rb.tt",
          File.join(db_migrate_path, "ecs_rails_shared_markers.rb")
        )
      end

      private

      # Component tables (any table with an entity_id column, other than
      # `entities` itself) that have no `slot` column yet — minus the backing
      # tables the relationships migration drops. Sorted, so the migration is
      # deterministic; uniq, because a multi-schema search_path can list one
      # name twice (the columns then resolve to the first schema).
      def tables_missing_slot
        @tables_missing_slot ||= component_tables.select do |table|
          !column_names(table).include?("slot") &&
            backing_tables.none? { |b| b[:table] == table } &&
            marker_tables.none? { |m| m[:table] == table }
        end
      end

      # Pre-0.3 marker tables: a component table with no attribute columns at all
      # — only id, entity_id, (slot,) timestamps — other than `markers` itself.
      # Each becomes `{ table: "moderators", slot: "moderator" }`.
      def marker_tables
        @marker_tables ||= component_tables.filter_map do |table|
          next if table == "markers"
          next unless (column_names(table) - %w[id entity_id slot created_at updated_at]).empty?

          { table: table, slot: table.singularize }
        end
      end

      def component_tables
        @component_tables ||= connection.tables.uniq.sort.select do |table|
          table != "entities" && column_names(table).include?("entity_id")
        end
      end

      # The catalogue components this upgrade brings forward: the selected sets,
      # plus any component the application already has a one-line class for,
      # whatever its set (an app that installed `commerce` earlier keeps getting
      # its upgrades). The class file, not the table, is the evidence: a bespoke
      # table that merely shares a catalogue name (`names`, say) must not be
      # "upgraded" with the catalogue's columns. Within a selected set the table
      # IS treated as the catalogue's — the developer asked for that set.
      def upgradeable_components
        @upgradeable_components ||= (catalogue_components +
          EcsRails::Catalogue.components.select { |c| catalogue_class_file?(c) }).uniq
      end

      # Does the components directory hold a class including this concern?
      def catalogue_class_file?(component)
        dir = File.join(destination_root, EcsRails.config.components_path)
        return false unless File.directory?(dir)

        Dir.glob(File.join(dir, "*.rb")).any? do |file|
          File.read(file).include?("include EcsRails::Catalogue::#{component.class_name}")
        end
      end

      # `[{ component:, source: }]` — the migration source for each component
      # whose table is missing, or is missing a column or index. Empty when the
      # catalogue is current.
      def catalogue_changes
        @catalogue_changes ||= upgradeable_components.filter_map do |component|
          table = component.table
          source =
            if connection.tables.include?(table)
              component.schema.to_ruby_diff(
                table_name: table,
                existing_columns: column_names(table),
                existing_indexes: connection.indexes(table).map(&:columns)
              )
            else
              component.schema.to_ruby(table_name: table)
            end
          { component: component, source: source } unless source.empty?
        end
      end

      # ADR-0013 backing tables, recognised by shape and name: columns are
      # exactly id, entity_id, one `<name>_id` uuid, timestamps (plus slot, if a
      # slots upgrade already ran), and the table is `<owner>_<names>` with a
      # non-empty owner. Each becomes
      # `{ table:, slot: "author", foreign_key: "author_id", owner_model: "posts" }`.
      # The `relationships` table itself is excluded by shape (it has more
      # columns), and a bespoke component with a single foreign key but its own
      # name (`sponsors`) is excluded by the name rule.
      def backing_tables
        @backing_tables ||= component_tables.filter_map do |table|
          columns = column_names(table) - %w[id entity_id slot created_at updated_at]
          next unless columns.size == 1

          foreign_key = columns.first
          next unless foreign_key.end_with?("_id") && column_type(table, foreign_key) == :uuid

          name = foreign_key.delete_suffix("_id")
          suffix = "_#{name.pluralize}"
          next unless table.end_with?(suffix) && table.length > suffix.length

          owner = table.delete_suffix(suffix)
          { table: table, slot: name, foreign_key: foreign_key, owner_model: owner.pluralize }
        end
      end

      def column_names(table)
        connection.columns(table).map(&:name)
      end

      def column_type(table, column)
        connection.columns(table).find { |c| c.name == column }&.type
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
