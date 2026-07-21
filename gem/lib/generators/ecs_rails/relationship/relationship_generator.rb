# frozen_string_literal: true

# See the note in component_generator.rb: rails/generators/active_record/migration
# references ActiveRecord::Migration without loading it, so these are required
# explicitly for load-isolation (generator_isolation_spec.rb).
require "active_record"
require "rails/generators/named_base"
require "rails/generators/active_record/migration"

# ADR-0010: the generator reads EcsRails.config. Require the library explicitly so
# the generator stands on its own requires (RFC-0008's isolation note).
require "ecs_rails"

module EcsRails
  module Generators
    # `rails g ecs_rails:relationship OWNER name:Target`
    #
    #   rails g ecs_rails:relationship Post author:User
    #
    # Implements RFC-0012 / ADR-0013. Unlike the component generator, this emits
    # ONLY a migration — `relates_to` defines the backing component dynamically,
    # so there is no model file to write. It prints a reminder to add the
    # `relates_to` line to the entity.
    #
    # The migration creates the owner-scoped backing table `post_authors`:
    #   - uuid PK,
    #   - entity_id: not-null, UNIQUE index, ON DELETE CASCADE FK to entities —
    #     the owner side (a post has at most one author; destroying the post
    #     destroys the link),
    #   - author_id: indexed, ON DELETE **NULLIFY** FK to entities — the target
    #     side (destroying the target nullifies, does not cascade to the owner),
    #   - timestamps.
    #
    # The single `name:Target` argument does not fit Rails' GeneratedAttribute
    # (there is no `:Target` column type), so it is parsed by hand — see
    # #parse_relationship!.
    class RelationshipGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :relationship, type: :string, banner: "name:Target"

      desc "Creates the migration for a relationship's backing table (no model)."

      def create_migration_file
        parse_relationship!
        migration_template(
          "migration.rb.tt",
          File.join(db_migrate_path, "create_#{backing_table_name}.rb")
        )
      end

      # RFC-0012: no component file. The DSL defines the backing component; the
      # developer only has to declare the relationship on the entity.
      def print_relates_to_reminder
        entity_path = File.join(EcsRails.config.entities_path, class_path, "#{file_name}.rb")
        say "Add the relationship to #{entity_path}:", :green
        say "    relates_to :#{relation_name}, #{target_class_name}"
      end

      private

      # Splits the `name:Target` argument. `file_name` (from NamedBase) is the
      # OWNER, e.g. "post"; `relationship` is "author:User".
      def parse_relationship!
        @relation_name, @target_class_name = relationship.split(":", 2)

        return unless @relation_name.to_s.empty? || @target_class_name.to_s.empty?

        raise Thor::Error,
              "expected OWNER name:Target, e.g. " \
              "`rails g ecs_rails:relationship Post author:User` (got #{relationship.inspect})"
      end

      attr_reader :relation_name, :target_class_name

      # The owner-scoped backing table: #{owner.singular}_#{relation.plural} —
      # `post_authors`. Mirrors the derivation in EcsRails::Relationships.
      def backing_table_name
        "#{singular_table_name}_#{relation_name.pluralize}"
      end

      # The target FK column: `author_id`. Mirrors EcsRails::Relationships.
      def target_foreign_key
        "#{relation_name}_id"
      end

      def migration_version
        "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
