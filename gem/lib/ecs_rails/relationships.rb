# frozen_string_literal: true

# #constantize is load-bearing for reload safety: relationship metadata stores
# the target class *name* (a string) and resolves it on read, so a reloaded
# constant is picked up — the same discipline as the registry (RFC-0002).
require "active_support/core_ext/string/inflections"

module EcsRails
  # The class-level DSL for cross-entity links: `relates_to`.
  #
  # Implements RFC-0012 / RFC-0013, decided by ADR-0013 and re-based on the
  # shared `relationships` table by ADR-0017. Extended into EcsRails::Entity,
  # alongside the `component` DSL it is built on.
  #
  #   class Post < ApplicationEntity
  #     relates_to :author, User
  #   end
  #
  #   class Invoice < ApplicationEntity
  #     relates_to :order, Order, unique: true   # at most one Invoice per Order
  #   end
  #
  #   post.author = user          # writer (checked against User)
  #   post.author                 # => the User
  #   post.author_id              # => the User's id
  #   post.author_relationship    # => the backing Relationship row (the reader)
  #
  # ## How a relationship is stored (ADR-0017)
  #
  # Every relationship in the application is a row in ONE `relationships` table,
  # created at install. `relates_to :author, User` is
  #
  #   component Relationship, prefix: :author, delegate: false,
  #             target_class_name: "User", unique: false
  #
  # — a labelled component (RFC-0014) whose slot is the relationship name. The
  # reader is `author_relationship`, the slot-scoped has_one every labelled
  # component gets, and the lazy reader presets `slot = "author"` on a virtual.
  # Nothing is defined dynamically: no backing class, no per-relationship table,
  # no migration. The `Relationship` class is the host app's one-line catalogue
  # component (EcsRails::Catalogue::Relationship), found by name through
  # {EcsRails::Config#relationship_class_name}.
  #
  # `delegate: false` because the component's own accessor is `target`; the
  # DSL here defines `author` / `author=` / `author_id` / `author_id=` by hand,
  # forwarding to the reader's `target`. The target type is checked on
  # assignment by the component (`post.author = company` raises
  # InvalidRelationship), against the `target_class_name` slot option.
  #
  # ## Querying and preloading by name (RFC-0013 / ADR-0014)
  #
  # `with_related` / `without_related` / `includes_related` are the
  # relationship-name equivalents of `with_component` / `without_component` /
  # `includes_components`. Each resolves the relationship name to its slot via
  # the metadata `relates_to` records, then delegates to the component verb —
  # so `Post.with_related(:author, ada)` compiles to exactly
  # `Post.with_component(Relationship, prefix: :author, target_id: ada.id)` and
  # inherits its entity-model scoping and EXISTS correctness (ADR-0011). Under
  # the shared table that scope is load-bearing, not belt-and-braces: a Comment
  # and a Post both relating `:author` share the table and the slot, and only
  # the owner's `model` tells them apart (ADR-0014, amended).
  module Relationships
    # One recorded relationship, held by NAME so it survives a Rails reload the
    # same way the registry's {EcsRails::Registry::Declaration} does (RFC-0002):
    # {#target_class} resolves via `constantize` on read.
    #
    # @!attribute [rw] name
    #   @return [Symbol] the relationship name, e.g. `:author`
    # @!attribute [rw] target_class_name
    #   @return [String] the entity pointed at, e.g. `"User"`
    # @!attribute [rw] unique
    #   @return [Boolean] whether rows are written `exclusive` (ADR-0017)
    RelationshipMeta = Struct.new(:name, :target_class_name, :unique) do
      # @return [Class<EcsRails::Entity>] the entity this relationship points at
      # @raise [NameError] if the constant no longer exists
      def target_class
        target_class_name.constantize
      end

      # @return [String] the slot the rows are stored under — the name
      def slot
        name.to_s
      end

      # @return [Symbol] the backing reader, `:author_relationship`
      def reader_name
        :"#{name}_relationship"
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
    # Pure Ruby: a row in the shared `relationships` table under slot `name`
    # (ADR-0017). Declares the app's `Relationship` component into that slot with
    # {EcsRails::DSL#component}, so the whole stack — registry, lazy reader,
    # querying, presence, preloading — applies for free, and defines the
    # `name` / `name=` / `name_id` / `name_id=` accessors on the entity.
    #
    # Subclasses inherit the declaration exactly as they inherit `component`.
    #
    # @example Declaring and using a relationship
    #   class Post < ApplicationEntity
    #     relates_to :author, User
    #   end
    #
    #   post.author = user        # checked: must be a User
    #   post.author               # => #<User>
    #   post.author_relationship  # => the backing Relationship row
    #
    # @example An exclusive link — at most one Invoice per Order (ADR-0017)
    #   class Invoice < ApplicationEntity
    #     relates_to :order, Order, unique: true
    #   end
    #
    # @param name [Symbol, String] the relationship name. Becomes the slot, the
    #   accessors (`#author`, `#author=`, `#author_id`, `#author_id=`), and the
    #   `<name>_relationship` backing reader.
    # @param target_class [Class<EcsRails::Entity>] a concrete entity to point at
    # @param unique [Boolean] `true` writes rows as `exclusive`, so the database
    #   rejects a second owner of this entity type pointing at the same target
    #   under this name
    # @return [EcsRails::Registry::Declaration] the Relationship declaration
    # @raise [EcsRails::InvalidRelationship] if `target_class` is not a concrete
    #   entity — a component, an abstract entity, or a plain class
    # @raise [EcsRails::DelegationConflict] if `name` collides with an existing
    #   component reader, delegated method, or another relationship
    # @raise [ArgumentError] if `unique:` is not a Boolean
    # @raise [NameError] if the app has no `Relationship` component (run
    #   `rails g ecs_rails:install`, or set {EcsRails::Config#relationship_class_name})
    # @see #with_related
    # @see #includes_related
    def relates_to(name, target_class, unique: false)
      name = name.to_sym

      # Target first: this must fire before any name derivation, so that
      # `Class.new(ApplicationEntity).relates_to(:x, String)` raises on the bad
      # target rather than on the anonymous entity's blank model_name.
      validate_relationship_target!(name, target_class)
      validate_unique_flag!(name, unique)

      # Then the name, with a relationship-shaped message. Left to `component`,
      # a re-declared relationship trips the registry's DuplicateComponent, whose
      # message names the component ("Relationship in slot \"author\"") rather
      # than the relationship the developer wrote (`:author`).
      detect_relationship_collision!(name)

      declaration = component(
        ecs_relationship_class,
        prefix: name,
        delegate: false,
        target_class_name: target_class.name,
        unique: unique
      )

      define_relationship_accessors(name)

      # RFC-0013 / ADR-0014: record the relationship metadata the `*_related`
      # query verbs resolve against. Recorded here, at declaration, so there is
      # one source of truth for the slot and target rather than a second place
      # that re-derives them. On reload the entity class body reruns on a fresh
      # class, repopulating this from empty.
      record_relationship_meta(name, target_class, unique)

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
    # Sugar over {EcsRails::Querying#with_component} on the shared Relationship
    # component, slot-scoped, so it inherits that verb's entity-model scoping and
    # correlated EXISTS (ADR-0011) — no cross-entity leak even though every
    # entity's relationships share one table (ADR-0017).
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
      backing = ecs_relationship_class

      return with_component(backing, prefix: meta.name) if ANY_TARGET.equal?(target)

      id = target.respond_to?(:id) ? target.id : target
      with_component(backing, prefix: meta.name, target_id: id)
    end

    # Entities with NO row for `name` (RFC-0013).
    #
    # Sugar over {EcsRails::Querying#without_component}, slot-scoped; inherits
    # its NULL-safe `NOT EXISTS` (ADR-0011).
    #
    # @example Orphaned posts
    #   Post.without_related(:author)
    #
    # @param name [Symbol, String] a declared relationship name
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidRelationship] if `name` is not declared
    # @see #with_related
    def without_related(name)
      meta = ecs_resolve_relationship!(name)
      without_component(ecs_relationship_class, prefix: meta.name)
    end

    # Preloads each named relationship's row AND its target entity — one hop —
    # so `entity.author` costs no extra query (RFC-0013 / ADR-0014).
    #
    # For `:author` that is `preload(author_relationship: :target)`. Does **not**
    # preload the target's own components (ADR-0014 non-goal) — chain
    # {EcsRails::Preloading#includes_components} on the target for that, or
    # write the nested preload by hand: `preload(author_relationship: { target:
    # :name })`.
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
        { ecs_resolve_relationship!(name).reader_name => :target }
      end

      all.preload(*preloads)
    end

    private

    # The host app's Relationship component (EcsRails::Catalogue::Relationship),
    # resolved by name on every call so a reloaded constant is picked up.
    def ecs_relationship_class
      EcsRails.config.relationship_class_name.constantize
    rescue NameError => e
      raise NameError,
            "EcsRails: `relates_to` needs the #{EcsRails.config.relationship_class_name} " \
            "component (#{e.message}). Run `rails g ecs_rails:install`, which writes it, " \
            "or set EcsRails.config.relationship_class_name to your class that includes " \
            "EcsRails::Catalogue::Relationship.", e.backtrace
    end

    # The four accessors a relationship gives the entity, into the same module
    # the readers and delegated methods live in (ADR-0004: an entity-defined
    # method still wins). Each goes through the slot-scoped reader, so it reaches
    # RFC-0006's memoised instance — the one the save cascade persists — and
    # `Post.create!(author: user)` routes through `author=` for free.
    def define_relationship_accessors(name)
      reader = :"#{name}_relationship"
      mod = generated_component_methods

      mod.define_method(name) { public_send(reader).target }
      mod.define_method(:"#{name}=") { |value| public_send(reader).target = value }
      mod.define_method(:"#{name}_id") { public_send(reader).target_id }
      mod.define_method(:"#{name}_id=") { |value| public_send(reader).target_id = value }
    end

    # The names a relationship reserves on the entity, for the DSL's conflict
    # checks (EcsRails::DSL#ecs_reserved_names): a later `component Foo, prefix:
    # false` delegating `author` must clash with `relates_to :author`, and a
    # `relates_to :email` must clash with `component Email`'s reader. Overrides
    # the DSL's empty default.
    def ecs_reserved_names
      relationship_names.each_with_object(super) do |name, reserved|
        [name, :"#{name}=", :"#{name}_id", :"#{name}_id="].each do |method|
          reserved[method] ||= "relates_to :#{name}"
        end
      end
    end

    # Records one relationship's metadata on THIS class, by name and by class
    # NAME (a string), never a Class object (reload safety — see RelationshipMeta).
    def record_relationship_meta(name, target_class, unique)
      ecs_own_relationships[name] = RelationshipMeta.new(name, target_class.name, unique)
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

    def validate_unique_flag!(name, unique)
      return if unique == true || unique == false

      raise ArgumentError,
            "relates_to :#{name} expects `unique:` to be true or false; got #{unique.inspect}"
    end

    # RFC-0012: `name` must not already be a reader or a delegated method on this
    # entity — two `relates_to :author`, or `:author` clashing with a component
    # that already exposes `author`. Checked here, before `component` runs, so the
    # message names `:author` (the relationship) rather than the slot.
    #
    # Reuses the DSL's own reader/delegation resolution (Declaration#reader_name,
    # #delegation_map_for — the entity-level names, prefixed per ADR-0016) plus
    # the names earlier relationships reserved, so "what names does this entity
    # already answer" is computed the one way the gem computes it everywhere else.
    def detect_relationship_collision!(name)
      taken = component_declarations.flat_map do |declaration|
        [declaration.reader_name] + delegation_map_for(declaration).keys
      end
      taken += ecs_reserved_names.keys

      clash = [name, :"#{name}_id"].find { |method| taken.include?(method) }
      return unless clash

      raise DelegationConflict,
            "relates_to :#{name} on #{self.name} collides with an existing " \
            "##{clash} method — a component reader, a delegated method, or another " \
            "relationship already owns that name. Choose a different relationship name."
    end
  end
end
