# frozen_string_literal: true

module EcsRails
  # The class-level DSL for markers: `marker`.
  #
  # Implements ADR-0018 §4 (RFC-0016), which amends ADR-0009's rejection of a
  # `marker` keyword. Extended into EcsRails::Entity after {DSL}, {Relationships}
  # and {Querying}, all of which it is built on.
  #
  #   class User < ApplicationEntity
  #     marker :moderator
  #     marker :administrator
  #   end
  #
  #   user.add(:moderator)            # a row in markers, slot "moderator"
  #   user.moderator?                 # => true — the row exists
  #   user.moderator = false          # remove; `= true` adds
  #   user.remove(:moderator)
  #   User.with_marker(:moderator)    # entities that have the row
  #   User.without_marker(:moderator)
  #
  # ## How a marker is stored (ADR-0018 §4)
  #
  # `marker :moderator` is
  #
  #   component Marker, prefix: :moderator, delegate: false
  #
  # — a labelled component (RFC-0014) with no attributes, whose slot is the
  # marker name, on the one `markers` table created at install. The reader is
  # `moderator_marker`; presence semantics are exactly ADR-0009's: a user *is* a
  # moderator when the `(entity_id, "moderator")` row exists, `add` writes it
  # now (the save cascade never would — a marker is never dirty), `remove`
  # destroys it.
  #
  # What the declaration adds over a bare `component` is the ergonomics
  # prefixing takes away: the predicate is `moderator?`, not
  # `moderator_marker?`; `add`/`has?`/`remove` take the Symbol; and
  # `moderator=` accepts a Boolean so a form checkbox routes through flat mass
  # assignment. The `Marker` class is the host app's one-line catalogue
  # component (EcsRails::Catalogue::Marker), found by name through
  # {EcsRails::Config#marker_class_name}.
  module Markers
    # Declares a marker named `name`.
    #
    # @example
    #   class User < ApplicationEntity
    #     marker :moderator
    #   end
    #
    #   user.add(:moderator)
    #   user.moderator?            # => true
    #   user.moderator = false     # removes the row
    #
    # @param name [Symbol, String] the marker name; becomes the slot, the
    #   `name?` predicate, the `name=` writer, and the `name_marker` reader
    # @return [EcsRails::Registry::Declaration] the Marker declaration
    # @raise [EcsRails::DelegationConflict] if `name?` or `name=` is already a
    #   method the entity answers
    # @raise [ArgumentError] if `name` is not a valid slot label
    # @raise [NameError] if the app has no `Marker` component (run
    #   `rails g ecs_rails:install`, or set {EcsRails::Config#marker_class_name})
    # @see EcsRails::Presence::Entity#add
    # @see #with_marker
    def marker(name)
      name = name.to_sym
      detect_marker_collision!(name)

      declaration = component(ecs_marker_class, prefix: name, delegate: false)
      define_marker_accessors(name)
      ecs_own_markers << name unless ecs_own_markers.include?(name)

      declaration
    end

    # The declared marker names for this entity, ancestry included.
    #
    # @example
    #   User.marker_names  # => [:moderator, :administrator]
    #
    # @return [Array<Symbol>]
    def marker_names
      entity_ancestry.flat_map { |klass| klass.instance_variable_get(:@ecs_markers) || [] }.uniq
    end

    # Is `name` a marker this entity declares?
    #
    # @param name [Symbol, String]
    # @return [Boolean]
    def marker?(name)
      marker_names.include?(name.to_sym)
    end

    # Entities that HAVE the marker (RFC-0010 sugar, ADR-0018 §4).
    #
    # @example
    #   User.with_marker(:moderator)
    #
    # @param name [Symbol, String] a declared marker
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidComponent] if `name` is not a declared marker
    # @see #without_marker
    def with_marker(name)
      with_component(ecs_marker_class, prefix: ecs_resolve_marker!(name))
    end

    # Entities that do NOT have the marker.
    #
    # @example
    #   User.without_marker(:administrator)
    #
    # @param name [Symbol, String] a declared marker
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidComponent] if `name` is not a declared marker
    # @see #with_marker
    def without_marker(name)
      without_component(ecs_marker_class, prefix: ecs_resolve_marker!(name))
    end

    private

    # The host app's Marker component (EcsRails::Catalogue::Marker), resolved
    # by name on every call so a reloaded constant is picked up.
    def ecs_marker_class
      EcsRails.config.marker_class_name.constantize
    rescue NameError => e
      raise NameError,
            "EcsRails: `marker` needs the #{EcsRails.config.marker_class_name} component " \
            "(#{e.message}). Run `rails g ecs_rails:install`, which writes it, or set " \
            "EcsRails.config.marker_class_name to your class that includes " \
            "EcsRails::Catalogue::Marker.", e.backtrace
    end

    # The bare predicate and the Boolean writer, into the same module the
    # readers live in (ADR-0004: an entity-defined method still wins). Both are
    # sugar over Presence: `moderator?` is `has?(:moderator)`, `moderator = x`
    # is `add`/`remove`. The writer is what lets a checkbox param route through
    # flat mass assignment (`User.update(moderator: "1")`); it takes anything
    # ActiveModel would cast as a Boolean.
    def define_marker_accessors(name)
      mod = generated_component_methods

      mod.define_method(:"#{name}?") { has?(name) }
      mod.define_method(:"#{name}=") do |value|
        ActiveModel::Type::Boolean.new.cast(value) ? add(name) : remove(name)
      end
    end

    # The names a marker reserves on the entity, for the DSL's conflict checks
    # (EcsRails::DSL#ecs_reserved_names). Extends whatever Relationships (and
    # the DSL) reserved.
    def ecs_reserved_names
      marker_names.each_with_object(super) do |name, reserved|
        [:"#{name}?", :"#{name}="].each { |method| reserved[method] ||= "marker :#{name}" }
      end
    end

    def ecs_own_markers
      @ecs_markers ||= []
    end

    # A marker name resolves to its slot, or raises the fail-loud
    # InvalidComponent naming the declared markers — the same stance as
    # relationships (RFC-0013).
    def ecs_resolve_marker!(name)
      return name.to_sym if marker?(name)

      declared = marker_names
      known = declared.empty? ? "none" : declared.map { |n| ":#{n}" }.join(", ")
      raise InvalidComponent,
            "#{self.name} has no marker named :#{name}. #{self.name} marks: #{known}."
    end

    # ADR-0004: the predicate and writer a marker generates must not be names
    # the entity already answers — a component reader's `email?` predicate, a
    # delegated `verified=`, a relationship's writer, another marker. The reader
    # (`moderator_marker`) is checked by `component` itself a moment later.
    def detect_marker_collision!(name)
      # The same marker twice is a DuplicateComponent, which `component` raises
      # a moment later with the slot named; reporting it here as a collision
      # with its own predicate would be the less useful message.
      return if marker_names.include?(name)

      taken = component_declarations.flat_map do |declaration|
        [declaration.reader_name, :"#{declaration.reader_name}?"] + delegation_map_for(declaration).keys
      end
      taken += ecs_reserved_names.keys

      clash = [:"#{name}?", :"#{name}="].find { |method| taken.include?(method) }
      return unless clash

      raise DelegationConflict,
            "marker :#{name} on #{self.name} collides with an existing ##{clash} method — " \
            "a component, a relationship or another marker already owns that name. " \
            "Choose a different marker name."
    end
  end
end
