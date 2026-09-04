# frozen_string_literal: true

module EcsRails
  # Batch component loads so a list view issues a bounded number of queries
  # instead of one per component per row.
  #
  # Implements RFC-0011, decided by ADR-0012. Surfaced by the demo, where the
  # 2-post index fired 14 queries (one per component per row).
  #
  #   Post.published.includes_components                    # all declared components
  #   User.includes_components(Name, Email)                 # a named subset
  #   Post.with_component(PublishState).includes_components(Title, Body)
  #
  # Extended into EcsRails::Entity, so these are class methods on every entity
  # class. Like Querying, ActiveRecord delegates class methods to relations, so
  # `User.where(...).includes_components(...)` chains: the method runs with `all`
  # returning the current relation, which already carries the entity-model scope.
  #
  # ## The finding this rests on (ADR-0012)
  #
  # This method builds no preload machinery. Each component is a `has_one`
  # (RFC-0004), and RFC-0006's lazy reader overrides that has_one but calls
  # `super`, reaching it underneath — so ActiveRecord's own `preload` already
  # batches component loads AND the lazy reader still returns a *virtual* instance
  # for an entity with no row (the has_one preloads to nil-and-loaded, the reader
  # builds the virtual). `includes_components` is a thin, discoverable wrapper
  # over `preload(*association_names)`; the regression tests in
  # spec/preloading_spec.rb pin the native path so it cannot silently break.
  module Preloading
    # Preloads the given components and returns a chainable relation.
    #
    # With no arguments, preloads *every* declared component of the entity —
    # walking inherited declarations (RFC-0004) via #components — which is the one
    # affordance the raw `preload(:a, :b, :c)` cannot offer.
    #
    # Takes component **classes**, not association symbols, consistent with
    # `with_component` / `add` / `has?`. Each must be a component declared on the
    # entity; otherwise EcsRails::InvalidComponent naming it, rather than leaking
    # ActiveRecord's `AssociationNotFoundError` and the has_one abstraction the gem
    # otherwise hides (ADR-0012).
    #
    # Uses `preload` (separate queries), never `includes`/`eager_load`: one extra
    # query per component, predictable, and no surprise JOIN that changes row
    # identity or interacts with `with_component`'s EXISTS. A developer who wants a
    # JOIN calls `eager_load` on the association names directly.
    #
    # Built from `all` — like Querying — so it chains onto any prior scope and
    # keeps the entity-model default scope (ADR-0002/ADR-0011).
    #
    # @example Every declared component
    #   Post.published.includes_components
    #
    # @example A named subset, chained onto a component filter
    #   Post.with_component(PublishState).includes_components(Title, Body)
    #
    # A component declared under several slots (RFC-0014) preloads every slot's
    # has_one: `includes_components(PostalAddress)` batches `postal_address` and
    # `business_address` alike, one query each.
    #
    # @param component_classes [Array<Class<EcsRails::Component>>] components to
    #   preload; empty preloads every component the entity declares
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidComponent] if any argument is not a component, or
    #   is not declared on this entity — unlike {EcsRails::Querying#with_component},
    #   which accepts any concrete component
    # @see EcsRails::Relationships#includes_related for relationships
    def includes_components(*component_classes)
      declarations = component_declarations
      targets =
        if component_classes.empty?
          declarations
        else
          component_classes.flat_map { |component_class| ecs_declarations_of!(component_class, declarations) }
        end

      all.preload(*targets.map(&:reader_name))
    end

    private

    # Every declaration of `component_class` on this entity — one per slot
    # (RFC-0014). Each reader name is the has_one the DSL defined, so preloading
    # by reader name is the same derivation the DSL used
    # (EcsRails::DSL#define_component_association).
    def ecs_declarations_of!(component_class, declarations)
      ecs_validate_declared_component!(component_class, declarations.map(&:component_class).uniq)
      declarations.select { |declaration| declaration.component_class_name == component_class.name }
    end

    # A preloadable component is one this entity *declares* — unlike the query DSL
    # (RFC-0010), which accepts any concrete component. Preloading an undeclared
    # component could only ever preload a has_one that does not exist, so it is a
    # programming error, caught here with a component-shaped message (ADR-0012)
    # before any database work. `declared` is passed in so #components is walked
    # once per call, not once per argument.
    def ecs_validate_declared_component!(component_class, declared)
      unless component_class.is_a?(Class) && component_class < EcsRails::Component
        raise InvalidComponent,
              "#{component_class.inspect} is not an EcsRails::Component subclass"
      end

      return if declared.include?(component_class)

      raise InvalidComponent,
            "#{component_class.name} is not a component declared on #{name}. " \
            "#{name} is composed from: #{declared.map(&:name).join(', ')}."
    end
  end
end
