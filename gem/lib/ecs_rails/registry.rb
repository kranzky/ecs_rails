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
      # @!attribute [r] entity_class_name
      #   @return [String] the declaring entity's class name
      # @!attribute [r] component_class_name
      #   @return [String] the declared component's class name
      # @!attribute [r] options
      #   @return [Hash] the frozen `only:`/`except:` delegation options
      attr_reader :entity_class_name, :component_class_name, :options

      # @param entity_class_name [String] the declaring entity's class name
      # @param component_class_name [String] the declared component's class name
      # @param options [Hash] `only:`/`except:` delegation options
      def initialize(entity_class_name:, component_class_name:, options: {})
        @entity_class_name = entity_class_name
        @component_class_name = component_class_name
        @options = options.dup.freeze
        freeze
      end

      # Resolved live, so a reloaded constant is picked up.
      #
      # @return [Class<EcsRails::Entity>] the declaring entity class
      # @raise [NameError] if the constant has gone away. See {Registry#components_for}.
      def entity_class
        entity_class_name.constantize
      end

      # Resolved live, so a reloaded constant is picked up.
      #
      # @return [Class<EcsRails::Component>] the declared component class
      # @raise [NameError] if the constant has gone away
      def component_class
        component_class_name.constantize
      end

      # @param other [Object]
      # @return [Boolean] true if both declare the same component on the same
      #   entity with the same options
      def ==(other)
        other.is_a?(Declaration) &&
          entity_class_name == other.entity_class_name &&
          component_class_name == other.component_class_name &&
          options == other.options
      end
      alias eql? ==

      # @return [Integer] a hash consistent with {#==}, so Declarations work as
      #   Hash keys and in Sets
      def hash
        [self.class, entity_class_name, component_class_name, options].hash
      end

      # @return [String] e.g. `#<...Declaration User => Email {}>`
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
    #
    # @param entity_class [Class<EcsRails::Entity>] the declaring entity
    # @param component_class [Class<EcsRails::Component>] the declared component
    # @param options [Hash] `only:`/`except:` delegation options
    # @return [Declaration] the recorded declaration
    # @raise [EcsRails::DuplicateComponent] if this entity already declares this
    #   component (ADR-0005)
    # @raise [ArgumentError] if either class is anonymous, since the registry
    #   keys entries by class name
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
    #
    # Only the entity's *own* declarations — inheritance is walked on read by
    # {EcsRails::DSL#component_declarations}, not copied down here.
    #
    # @param entity_class [Class<EcsRails::Entity>] the entity to look up
    # @return [Array<Declaration>] its declarations; empty if none
    def components_for(entity_class)
      declarations = @declarations[name_for(entity_class)]
      declarations ? declarations.dup : []
    end

    # Every entity class declaring this component, as live class objects.
    #
    # @param component_class [Class<EcsRails::Component>] the component
    # @return [Array<Class<EcsRails::Entity>>] the entities composed from it
    # @raise [NameError] if a recorded entity constant has gone away
    def entities_for(component_class)
      component_name = name_for(component_class)

      @declarations.each_value.with_object([]) do |declarations, entities|
        declarations.each do |declaration|
          entities << declaration.entity_class if declaration.component_class_name == component_name
        end
      end
    end

    # Resets the registry. Used between tests and by the Railtie's `to_prepare`.
    #
    # @return [self]
    def clear!
      @declarations = {}
      self
    end

    # An opaque snapshot of the current declarations, for save/restore around a
    # block that mutates the registry — chiefly tests that `clear!` the
    # process-wide singleton and would otherwise wipe declarations that
    # host/app classes made at load time. `Declaration` is frozen and holds only
    # strings, so a shallow dup of the arrays is a safe, cheap copy.
    #
    # @return [Hash] an opaque snapshot to hand back to {#restore}
    # @see #restore
    def snapshot
      @declarations.transform_values(&:dup)
    end

    # Replaces the declarations with a previously taken {#snapshot}.
    #
    # @param snapshot [Hash] a value previously returned by {#snapshot}
    # @return [self]
    # @see #snapshot
    def restore(snapshot)
      @declarations = snapshot.transform_values(&:dup)
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
