# frozen_string_literal: true

# See the note in install_generator.rb: rails/generators/active_record/migration
# references ActiveRecord::Migration without loading it.
require "active_record"
require "rails/generators/named_base"
require "rails/generators/active_record/migration"

# Rails::Generators::GeneratedAttribute.parse calls String#remove, an
# ActiveSupport core extension that neither rails/generators nor active_record
# loads. A booted Rails app has active_support/all, so `rails g` works either
# way — but without this the attribute parsing below depends on some other file
# happening to have loaded the core ext first, which is not a dependency this
# generator should have.
require "active_support/core_ext/string/filters"

module Rorecs
  module Generators
    # `rails g rorecs:component NAME [field:type ...]`
    #
    # Implements RFC-0008. The whole point of this generator is that the
    # entity_id + UNIQUE index + ON DELETE CASCADE invariant (ADR-0005) becomes
    # impossible to forget, and that every attribute gets an explicit default
    # (RFC-0006).
    #
    # Attribute parsing is Rails' own: declaring an `attributes` argument makes
    # Rails::Generators::NamedBase run parse_attributes!, which turns
    # "address:string" into a Rails::Generators::GeneratedAttribute.
    class ComponentGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      argument :attributes, type: :array, default: [], banner: "field:type field:type"

      desc "Creates a component: its migration, its model, and its spec."

      def create_migration_file
        migration_template(
          "migration.rb.tt",
          File.join(db_migrate_path, "create_#{table_name}.rb")
        )
      end

      def create_model_file
        template "model.rb.tt", File.join("app/models", class_path, "#{file_name}.rb")
      end

      def create_spec_file
        template "component_spec.rb.tt",
                 File.join("spec/models", class_path, "#{file_name}_spec.rb")
      end

      private

      # The explicit-default policy (RFC-0008 / RFC-0006).
      #
      # A virtual component — one with no database row — reports its column
      # defaults. So a column with no default silently reports nil, and that
      # choice should be visible in the migration rather than implied. Every
      # attribute therefore gets a `default:` written out.
      #
      #   boolean => default: false, null: false
      #     A three-valued boolean has no sensible virtual reading: `user.email
      #     .verified` should be false, not nil. Matches spec/support/schema.rb's
      #     `verified` column. null: false because the default removes any
      #     reason for the column to be nullable.
      #
      #   everything else => default: nil
      #     There is no defensible universal default for a string or an integer,
      #     and inventing one (0, "") would be worse than nil. nil is written
      #     explicitly so the reader sees it was a decision.
      #
      # Override by hand in the generated migration when the domain has a real
      # default — that edit is the point.
      def column_options_for(attribute)
        case attribute.type.to_s
        when "boolean" then ", default: false, null: false"
        else ", default: nil"
        end
      end

      def migration_version
        "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
