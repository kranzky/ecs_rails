# frozen_string_literal: true

# #constantize is load-bearing for reload safety: relationship metadata stores
# the backing and target class *names* (strings) and resolves them on read, so a
# reloaded constant is picked up — the same discipline as the registry
# (RFC-0002). Required explicitly rather than relying on ActiveRecord.
require "active_support/core_ext/string/inflections"

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
  #
  # ## Querying and preloading by name (RFC-0013 / ADR-0014)
  #
  # `with_related` / `without_related` / `includes_related` are the
  # relationship-name equivalents of `with_component` / `without_component` /
  # `includes_components`. They are thin sugar: each resolves the relationship
  # name to its backing class and FK via metadata `relates_to` records, then
  # delegates to the component verb — so `Post.with_related(:author, ada)`
  # compiles to exactly `Post.with_component(Post::AuthorRelationship, author_id:
  # ada.id)` and inherits its entity-model scoping and EXISTS correctness
  # (ADR-0011). The backing `*Relationship` class never appears in app code.
  module Relationships
    # One recorded relationship, held by NAME so it survives a Rails reload the
    # same way the registry's {EcsRails::Registry::Declaration} does (RFC-0002):
    # {#backing_class} and {#target_class} resolve via `constantize` on read, so a
    # metadata entry taken before a reload still resolves to the post-reload
    # constants.
    #
    # @!attribute [rw] name
    #   @return [Symbol] the relationship name, e.g. `:author`
    # @!attribute [rw] backing_class_name
    #   @return [String] the dynamically defined backing component,
    #     e.g. `"Post::AuthorRelationship"`
    # @!attribute [rw] foreign_key
    #   @return [Symbol] the FK on the backing component, e.g. `:author_id`
    # @!attribute [rw] target_class_name
    #   @return [String] the entity pointed at, e.g. `"User"`
    RelationshipMeta = Struct.new(:name, :backing_class_name, :foreign_key, :target_class_name) do
      # @return [Class<EcsRails::Component>] the backing component class
      # @raise [NameError] if the constant no longer exists
      def backing_class
        backing_class_name.constantize
      end

      # @return [Class<EcsRails::Entity>] the entity this relationship points at
      # @raise [NameError] if the constant no longer exists
      def target_class
        target_class_name.constantize
      end
    end

    # Sentinel for with_related's optional target: distinguishes "no target
    # given" (filter to any backing row) from an explicit value. RFC-0013 only
    # needs the no-arg form, but a sentinel — rather than a nil default — keeps
    # "unset" from ever being confused with a legitimate id or entity.
    ANY_TARGET = Object.new
    private_constant :ANY_TARGET

    # Declares a cross-entity link named `name` at `target_class`.
    #
    # Writes no relationship component file: it defines the backing component
    # dynamically and declares it with {EcsRails::DSL#component}, so the whole
    # stack — registry, lazy reader, delegation, querying, presence, preloading —
    # applies for free.
    #
    # Subclasses inherit the declaration exactly as they inherit `component`.
    #
    # @example Declaring and using a relationship
    #   class Post < ApplicationEntity
    #     relates_to :author, User
    #   end
    #
    #   post.author = user        # writer, delegated from the backing belongs_to
    #   post.author               # => #<User>
    #   post.author_relationship  # => the backing component row
    #
    # @example Several relationships on one entity
    #   class Membership < ApplicationEntity
    #     relates_to :user, User
    #     relates_to :team, Team
    #     component Role
    #   end
    #
    # @param name [Symbol, String] the relationship name. Becomes the delegated
    #   accessor (`#author`, `#author=`), the `<name>_id` foreign key, and the
    #   `<name>_relationship` backing reader.
    # @param target_class [Class<EcsRails::Entity>] a concrete entity to point at
    # @return [EcsRails::Registry::Declaration] the backing component's declaration
    # @raise [EcsRails::InvalidRelationship] if `target_class` is not a concrete
    #   entity — a component, an abstract entity, or a plain class
    # @raise [EcsRails::DelegationConflict] if `name` collides with an existing
    #   component reader, delegated method, or another relationship
    # @see #with_related
    # @see #includes_related
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

      backing = build_relationship_component(name, target_class)
      declaration = component(backing)

      # RFC-0013 / ADR-0014: record the relationship metadata the `*_related`
      # query verbs resolve against. Recorded here, at declaration, so there is
      # one source of truth for the backing class + FK rather than a second
      # place that re-derives the naming convention (ADR-0014). On reload the
      # entity class body reruns on a fresh class, repopulating this from empty.
      record_relationship_meta(name, backing, target_class)

      declaration
    end

    # The recorded metadata for relationship `name` on this entity (RFC-0013).
    #
    # Walks the entity ancestry, so a subclass sees its parents' relationships —
    # the same way {EcsRails::DSL#component_declarations} does.
    #
    # @param name [Symbol, String] the relationship name
    # @return [RelationshipMeta, nil] the metadata, or nil if undeclared
    # @see #relationship_names
    def relationship_meta(name)
      relationship_declarations[name.to_sym]
    end

    # The declared relationship names for this entity, ancestry included.
    #
    # @example
    #   Membership.relationship_names  # => [:user, :team]
    #
    # @return [Array<Symbol>] declared relationship names
    # @see #relationship_meta
    def relationship_names
      relationship_declarations.keys
    end

    # Entities whose `name` relationship points at `target` (RFC-0013 / ADR-0014).
    #
    # Sugar over {EcsRails::Querying#with_component}, so it inherits that verb's
    # entity-model scoping and correlated EXISTS (ADR-0011) — no cross-entity
    # leak. The backing `*Relationship` class never appears in app code.
    #
    # @example Posts by a given author
    #   Post.with_related(:author, ada)
    #   Post.with_related(:author, ada.id)   # a bare id works too
    #
    # @example Posts that have *any* author set
    #   Post.with_related(:author)
    #
    # @param name [Symbol, String] a declared relationship name
    # @param target [EcsRails::Entity, Integer, String] the target entity or its
    #   id. Omit to match entities that merely have the relationship set.
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidRelationship] if `name` is not declared
    # @see #without_related
    # @see #includes_related
    def with_related(name, target = ANY_TARGET)
      meta = ecs_resolve_relationship!(name)

      return with_component(meta.backing_class) if ANY_TARGET.equal?(target)

      id = target.respond_to?(:id) ? target.id : target
      with_component(meta.backing_class, meta.foreign_key => id)
    end

    # Entities with NO backing row for `name` (RFC-0013).
    #
    # Sugar over {EcsRails::Querying#without_component}; inherits its NULL-safe
    # `NOT EXISTS` (ADR-0011).
    #
    # @example Orphaned posts
    #   Post.without_related(:author)
    #
    # @param name [Symbol, String] a declared relationship name
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidRelationship] if `name` is not declared
    # @see #with_related
    def without_related(name)
      without_component(ecs_resolve_relationship!(name).backing_class)
    end

    # Preloads each named relationship's backing component AND its target entity
    # — one hop — so `entity.author` costs no extra query (RFC-0013 / ADR-0014).
    #
    # For `:author` that is `preload(author_relationship: :author)`. Does **not**
    # preload the target's own components (ADR-0014 non-goal) — chain
    # {EcsRails::Preloading#includes_components} on the target for that.
    #
    # @example
    #   Post.published.includes_related(:author).each { |p| p.author.name }
    #
    # @param names [Array<Symbol, String>] declared relationship names
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidRelationship] if any name is not declared
    # @see #with_related
    def includes_related(*names)
      preloads = names.map do |name|
        meta = ecs_resolve_relationship!(name)
        { :"#{meta.name}_relationship" => meta.name }
      end

      all.preload(*preloads)
    end

    private

    # Records one relationship's metadata on THIS class, by name and by class
    # NAMES (strings), never Class objects (reload safety — see RelationshipMeta).
    def record_relationship_meta(name, backing, target_class)
      ecs_own_relationships[name] = RelationshipMeta.new(
        name,               # :author
        backing.name,       # "Post::AuthorRelationship"
        :"#{name}_id",      # :author_id
        target_class.name   # "User"
      )
    end

    # This class's OWN relationships (not inherited). A per-class hash, so a fresh
    # class object after a reload starts empty and `relates_to` repopulates it.
    # Instance variables are not inherited, which is exactly what lets
    # #relationship_declarations do the ancestry walk explicitly.
    def ecs_own_relationships
      @ecs_relationships ||= {}
    end

    # Every relationship declared on this entity, ancestors' before its own —
    # merged across #entity_ancestry the same way #component_declarations walks
    # it, so a subclass inherits its parents' relationships. Base-first merge
    # means a nearer class would win a name clash, mirroring method lookup.
    def relationship_declarations
      entity_ancestry.each_with_object({}) do |klass, merged|
        own = klass.instance_variable_get(:@ecs_relationships)
        merged.merge!(own) if own
      end
    end

    # Resolves `name` to its metadata or raises the fail-loud InvalidRelationship
    # (RFC-0013) — naming the relationship and this entity's declared ones, the
    # same component-shaped stance as the rest of the DSL.
    def ecs_resolve_relationship!(name)
      meta = relationship_meta(name)
      return meta if meta

      declared = relationship_names
      known = declared.empty? ? "none" : declared.map { |n| ":#{n}" }.join(", ")
      raise InvalidRelationship,
            "#{self.name} has no relationship named :#{name}. " \
            "#{self.name} relates to: #{known}."
    end

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
