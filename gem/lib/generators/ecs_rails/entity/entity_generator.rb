# frozen_string_literal: true

require "rails/generators/named_base"
require "ecs_rails"

module EcsRails
  module Generators
    # Generates an entity from existing component classes, without a migration.
    # References use `name` or `slot:name`; see RFC-0008's ECS-11 amendment.
    class EntityGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      argument :components, type: :array, default: [], banner: "component slot:component"
      desc "Creates an entity class from existing components; no migration."

      # Validate the whole request before handing file creation/collisions to
      # Thor. Reversal needs only the filename, not components that may be gone.
      #
      # @return [void]
      def create_entity_file
        validate_entity_name!
        @declarations = []
        if behavior == :invoke
          class_collisions(class_name) unless File.exist?(File.join(destination_root, entity_path))
          validate_base!
          @declarations = component_declarations
        end
        template "entity.rb.tt", entity_path
      end

      private

      def entity_path
        File.join(EcsRails.config.entities_path, class_path, "#{file_name}.rb")
      end

      def validate_entity_name!
        unless name.match?(/\A[A-Za-z]\w*(?:(?:\/|::)[A-Za-z]\w*)*\z/)
          raise Rails::Generators::Error, "Invalid entity name #{name.inspect}; use Person or Admin/Person."
        end
      end

      def validate_base!
        base = "ApplicationEntity".safe_constantize
        return if base.is_a?(Class) && base < EcsRails::Entity

        raise Rails::Generators::Error, "Run bin/rails generate ecs_rails:install and bin/rails db:migrate before generating entities."
      end

      def component_declarations
        seen = {}
        components.map do |reference|
          # A single colon labels a slot; double colons remain part of the
          # component namespace, alongside Rails' slash notation.
          match = reference.match(/\A(?:([a-z_][a-z0-9_]*):)?((?:::)?[A-Za-z]\w*(?:(?:\/|::)[A-Za-z]\w*)*)\z/)
          unless match
            raise Rails::Generators::Error, "Invalid component reference #{reference.inspect}; use email or home:address (lowercase slot labels)."
          end

          slot, component_name = match.captures
          component_name = component_name.delete_prefix("::").camelize
          component = resolve_component(component_name)
          key = [component.name, slot]
          if seen[key]
            raise Rails::Generators::Error, "Duplicate component #{reference.inspect}; each component/slot pair must be unique."
          end
          seen[key] = true

          # Absolute references in namespaced source keep a local constant from
          # changing which component the command resolved through autoloading.
          constant = class_path.empty? ? component.name : "::#{component.name}"
          declaration = "component #{constant}"
          declaration += ", prefix: :#{slot}" if slot
          declaration
        end
      end

      def resolve_component(component_name)
        component = component_name.safe_constantize
        unless component
          raise Rails::Generators::Error,
                "Component #{component_name} was not found. Run bin/rails generate ecs_rails:install " \
                "(or ecs_rails:upgrade) with the required --sets, then bin/rails db:migrate. " \
                "For bespoke storage, use bin/rails generate ecs_rails:component #{component_name} field:type."
        end
        unless component.is_a?(Class) && component < EcsRails::Component && !component.abstract_class?
          raise Rails::Generators::Error, "#{component_name} must be an existing concrete EcsRails::Component class."
        end
        component
      end
    end
  end
end
