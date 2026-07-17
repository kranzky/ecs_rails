# frozen_string_literal: true

# active_record must be required explicitly: rails/generators/active_record/
# migration references ActiveRecord::Migration and ActiveRecord::VERSION but
# does not load them itself. A host Rails app happens to have ActiveRecord
# loaded already, so omitting this only breaks in isolation — which is exactly
# where it is hardest to notice.
require "active_record"
require "rails/generators/named_base"
require "rails/generators/active_record/migration"

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

      def create_base_models
        template "application_entity.rb.tt", "app/models/application_entity.rb"
        template "application_component.rb.tt", "app/models/application_component.rb"
      end

      private

      # The `ActiveRecord::Migration[x.y]` version stamp, tracking whatever
      # ActiveRecord the host app is actually running.
      def migration_version
        "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
      end
    end
  end
end
