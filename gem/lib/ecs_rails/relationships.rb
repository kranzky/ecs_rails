# frozen_string_literal: true

module EcsRails
  # The class-level DSL for cross-entity links: `relates_to`.
  #
  # Implements RFC-0012, decided by ADR-0013. Extended into EcsRails::Entity,
  # alongside the `component` DSL it is built on. Surfaced by the demo, where
  # `Authorship`, `MemberUser` and `MemberGroup` were each *nothing but* a
  # `belongs_to` in a component, plus a `component` declaration and a migration.
  #
  #   class Post < ApplicationEntity
  #     relates_to :author, User
  #   end
  #
  #   class Membership < ApplicationEntity
  #     relates_to :user, User
  #     relates_to :team, Team
  #     component Role
  #   end
  #
  #   post.author = user   # writer   (delegated from the backing belongs_to)
  #   post.author          # => the User (delegated)
  #   post.author_relationship  # => the backing component row (the reader)
  #
  # `relates_to` writes no relationship component file. It defines the backing
  # component dynamically and then declares it with `component`, so the whole
  # RFC-0004/0005/0006/0009/0010/0011 stack applies for free: registry, lazy
  # reader, delegation, `with_component`, presence, `includes_components`.
  #
  # ## How the backing component is built (ADR-0013)
  #
  # `relates_to :author, User` on `Post` dynamically defines
  # `Post::AuthorRelationship`, a concrete EcsRails::Component subclass, with:
  #   - `table_name = "post_authors"` — `#{entity.singular}_#{relation.plural}`,
  #     owner-scoped so it is collision-free by construction (ADR-0013),
  #   - `belongs_to :author, class_name: "User", foreign_key: :author_id,
  #     optional: true` — the target link, optional so an unset relationship is
  #     valid (ADR-0003).
  #
  # Then it runs `component Post::AuthorRelationship`. Delegation surfaces the
  # `belongs_to` as `post.author` / `post.author=`; the backing component's own
  # reader is `post.author_relationship`. There is no reader collision, because
  # the component is named for the *relationship* and the association for the
  # *target* — the rule the ADR-0006 amendment arrived at the hard way.
  #
  # ## The reader name (RFC-0012 Open, resolved)
  #
  # The reader is `author_relationship`, not `post_author_relationship`. That is
  # a real trap: the DSL derives the reader (and has_one name, and preload key)
  # from `component_class.model_name.singular`, and for the *nested* constant
  # `Post::AuthorRelationship` that is "post_author_relationship" — the namespace
  # leaks in and the entity name is doubled up. ADR-0013 specifies
  # `author_relationship`. So the backing class pins its own `model_name` to the
  # demodulized element ("AuthorRelationship" => "author_relationship"), which is
  # the single source every DSL derivation reads. Nothing else in the gem uses
  # the backing component's model_name, so this is safe and total: reader,
  # has_one, and `includes_components` key all agree on `author_relationship`.
  module Relationships
    # Declares a cross-entity link named `name` at `target_class`.
    #
    # `target_class` must be a concrete EcsRails::Entity; otherwise
    # InvalidRelationship (a subclass of InvalidComponent — see errors.rb). `name`
    # must not collide with an existing reader or delegated method on the entity;
    # otherwise DelegationConflict, naming `name` (RFC-0012). Subclasses inherit
    # the declaration exactly as they inherit `component` (the backing const lives
    # on the declaring entity and resolves through ordinary constant lookup).
    #
    # Returns the Registry::Declaration for the backing component.
    def relates_to(name, target_class)
      name = name.to_sym

      # Target first: this must fire before any name/table derivation, so that
      # `Class.new(ApplicationEntity).relates_to(:x, String)` raises on the bad
      # target rather than on the anonymous entity's blank model_name.
      validate_relationship_target!(name, target_class)

      # Then the name, with a relationship-shaped message. Left to `component`,
      # a re-declared relationship trips the registry's DuplicateComponent, whose
      # message names the CamelCase backing class ("Post::AuthorRelationship")
      # rather than the relationship the developer wrote (`:author`) — and it
      # would also warn on the doubled const_set. Catching it here keeps the
      # message about the thing the developer typed.
      detect_relationship_collision!(name)

      component(build_relationship_component(name, target_class))
    end

    private

    # Dynamically defines the backing component class and returns it. Named
    # before anything reads its name: the registry keys by name and rejects
    # anonymous classes (RFC-0002), and `model_name` is derived from the const —
    # so const_set, which both installs the nested constant and gives the class
    # its name, must come first.
    def build_relationship_component(name, target_class)
      const_name = :"#{name.to_s.camelize}Relationship"       # :AuthorRelationship
      table = "#{model_name.singular}_#{name.to_s.pluralize}" # "post_authors"
      foreign_key = :"#{name}_id"                             # :author_id

      backing = Class.new(EcsRails::Component)
      const_set(const_name, backing)

      # table_name is set explicitly (ADR-0013): the class name and the table
      # name are decoupled, so `Post::AuthorRelationship` reads `post_authors`.
      backing.table_name = table

      # Pin model_name to the demodulized element, so the DSL-derived reader is
      # `author_relationship` and not `post_author_relationship` — see the module
      # comment. Closed over `const_name`; ActiveModel::Name.new(self, nil,
      # "AuthorRelationship") gives singular "author_relationship".
      element = const_name.to_s
      backing.define_singleton_method(:model_name) do
        @ecs_relationship_model_name ||= ActiveModel::Name.new(self, nil, element)
      end

      # The one sanctioned place a component names an entity class (ADR-0006):
      # optional, so a post with no author — or a nullified one — is valid.
      backing.belongs_to name,
                         class_name: target_class.name,
                         foreign_key: foreign_key,
                         optional: true

      backing
    end

    # RFC-0012: the target must be a concrete entity. A component, an abstract
    # entity, or a plain class is rejected with a relationship-shaped message.
    def validate_relationship_target!(name, target_class)
      unless target_class.is_a?(Class) && target_class < EcsRails::Entity
        raise InvalidRelationship,
              "relates_to :#{name} expected a concrete EcsRails::Entity as its " \
              "target, got #{target_class.inspect}. A relationship points at an " \
              "entity, not a component or a plain class."
      end

      return unless target_class.abstract_class?

      raise InvalidRelationship,
            "relates_to :#{name} target #{target_class.name} is abstract and owns " \
            "no rows; relate to a concrete entity subclass."
    end

    # RFC-0012: `name` must not already be a reader or a delegated method on this
    # entity — two `relates_to :author`, or `:author` clashing with a component
    # that already exposes `author`. Checked here, before the backing const is
    # created, so the message names `:author` (the relationship) rather than the
    # backing class, and no doubled const_set warning is printed.
    #
    # Reuses the DSL's own reader/delegation resolution (#reader_name_for,
    # #delegated_method_names), so "what names does this entity already answer"
    # is computed the one way the gem computes it everywhere else.
    def detect_relationship_collision!(name)
      taken = component_declarations.flat_map do |declaration|
        component = declaration.component_class
        [reader_name_for(component)] + delegated_method_names(component, declaration.options)
      end

      return unless taken.include?(name)

      raise DelegationConflict,
            "relates_to :#{name} on #{self.name} collides with an existing " \
            "##{name} method — a component reader or another relationship already " \
            "owns that name. Choose a different relationship name."
    end
  end
end
