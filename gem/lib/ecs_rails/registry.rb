# frozen_string_literal: true

# Required explicitly rather than relying on ActiveRecord having pulled them in:
# #constantize is load-bearing for reload safety.
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/string/filters"

module EcsRails
  # Records which components each entity declares. See RFC-0002.
  #
  # The registry is a process-wide singleton (`EcsRails.registry`) populated by the
  # `component` DSL (RFC-0004) at class-load time, and read by generators,
  # delegation and — later — systems.
  #
  # Reload safety is the whole design constraint. In development Rails does not
  # mutate a reloaded class in place: it removes the constant and autoloads a
  # brand-new Class object under the same name. A registry that held class
  # objects would pin the old, orphaned constants forever, and every lookup
  # would hand back classes the rest of the app has already forgotten. So
  # nothing here stores a Class: entries are keyed by class *name*, and names are
  # resolved back to live constants via #constantize at read time.
  class Registry
    # One `component Foo` declaration on one entity class.
    #
    # A value object over *names*. #entity_class / #component_class resolve on
    # every call, so a Declaration handed out before a reload still resolves to
    # the post-reload constants.
    class Declaration
      attr_reader :entity_class_name, :component_class_name, :options

      def initialize(entity_class_name:, component_class_name:, options: {})
        @entity_class_name = entity_class_name
        @component_class_name = component_class_name
        @options = options.dup.freeze
        freeze
      end

      # Raises NameError if the constant has gone away. See #components_for.
      def entity_class
        entity_class_name.constantize
      end

      def component_class
        component_class_name.constantize
      end

      def ==(other)
        other.is_a?(Declaration) &&
          entity_class_name == other.entity_class_name &&
          component_class_name == other.component_class_name &&
          options == other.options
      end
      alias eql? ==

      def hash
        [self.class, entity_class_name, component_class_name, options].hash
      end

      def inspect
        "#<#{self.class} #{entity_class_name} => #{component_class_name} #{options.inspect}>"
      end
    end

    def initialize
      clear!
    end

    # Records one declaration. Returns the Declaration.
    #
    # Raises DuplicateComponent if this entity already declares this component —
    # per ADR-0005 a component appears at most once per entity, and RFC-0004
    # relies on the raise to catch a doubled `component` line at class-load time.
    def register(entity_class:, component_class:, options: {})
      entity_name = name_for(entity_class)
      component_name = name_for(component_class)

      declarations = (@declarations[entity_name] ||= [])

      if declarations.any? { |declaration| declaration.component_class_name == component_name }
        raise DuplicateComponent,
              "#{entity_name} already declares #{component_name}"
      end

      declaration = Declaration.new(
        entity_class_name: entity_name,
        component_class_name: component_name,
        options: options
      )
      declarations << declaration
      declaration
    end

    # The declarations for an entity, in declaration order.
    #
    # Resolution is lazy, so this never raises for a stale entry; asking the
    # returned Declaration for #component_class does. That is deliberate: a
    # dangling name means the registry has drifted out of sync with the app, and
    # silently dropping the entry would make generators emit an incomplete schema
    # and delegation quietly stop working. #clear! is the supported way to drop
    # entries, and the Railtie calls it on every reload.
    def components_for(entity_class)
      declarations = @declarations[name_for(entity_class)]
      declarations ? declarations.dup : []
    end

    # Every entity class declaring this component, as live class objects.
    def entities_for(component_class)
      component_name = name_for(component_class)

      @declarations.each_value.with_object([]) do |declarations, entities|
        declarations.each do |declaration|
          entities << declaration.entity_class if declaration.component_class_name == component_name
        end
      end
    end

    # Resets the registry. Used between tests and by the Railtie's `to_prepare`.
    def clear!
      @declarations = {}
      self
    end

    private

    # The one place a Class is turned into a String — and the only thing the
    # registry ever retains.
    def name_for(klass)
      raise ArgumentError, "expected a Class, got #{klass.inspect}" unless klass.is_a?(Module)

      klass.name || raise(ArgumentError, <<~MESSAGE.squish)
        cannot register an anonymous class: the registry keys entries by class
        name so they survive Rails reloading. Assign the class to a constant
        before declaring components on it.
      MESSAGE
    end
  end
end
