# frozen_string_literal: true

module EcsRails
  # The parent side of a relationship: `has_many` / `has_one` over the shared
  # `relationships` table (RFC-0015, on ADR-0017's storage).
  #
  #   class Comment < ApplicationEntity
  #     relates_to :post, Post              # the child owns the link
  #   end
  #
  #   class Post < ApplicationEntity
  #     has_many :comments, via: :post      # the parent reads it back; child inferred from the name
  #   end
  #
  #   post.comments                # a real ActiveRecord CollectionProxy of Comments
  #   post.comments << comment     # writes the relationships row
  #   post.comments.create!(...)   # a Comment whose :post is this post
  #   Post.includes(:comments)     # preloads, no N+1
  #
  #   class Invoice < ApplicationEntity
  #     relates_to :order, Order, unique: true
  #   end
  #
  #   class Order < ApplicationEntity
  #     has_one :invoice, via: :order       # requires unique: true on the child
  #   end
  #
  # ## The expansion
  #
  # Every `relates_to` is a row in `relationships` — `entity_id` the child,
  # `slot` the relationship name, `target_id` the parent, `owner_model` the
  # child's discriminator (ADR-0017). The parent's primary key *is* the
  # `entities.id` that `target_id` references, so the parent registers native
  # ActiveRecord associations over it. `has_many :comments, via: :post` expands to
  #
  #   has_many :comments_post_links,
  #            -> { where(slot: "post", owner_model: "comments") },
  #            class_name: "Relationship", foreign_key: :target_id, inverse_of: :target
  #   has_many :comments, through: :comments_post_links, source: :entity, class_name: "Comment"
  #
  # One shape for every inverse, and everything after it is Rails: the reader is
  # a real `CollectionProxy`, preloading is `includes(:comments)`, and
  # ADR-0008's read-time resolution returns `Comment`s (spiked before this
  # module was written). `owner_model` on the link scope is load-bearing —
  # without it a `Review` relating `:post` would be collected too — and
  # `class_name` on the through adds the entity-model scope as a second guard.
  # `has_one` is the same with a has_one link (`invoice_order_link`), because
  # ActiveRecord's has_one :through cannot pass through a collection.
  #
  # ## The child is named, not referenced — and validated on first use
  #
  # The child may be given as a class (`Comment`), a string (`"Comment"`), or
  # left to be inferred from the reader (`:comments` → `"Comment"`), exactly as
  # ActiveRecord's `class_name:` works. It is held as a NAME and resolved when
  # the association is used, for the reason Rails does the same: the parent
  # names the child and the child's `relates_to` names the parent, and under
  # autoloading a constant reference from either side loads the other *in the
  # middle of its own class body*. Referencing `Membership` from `Group`'s body
  # autoloads `membership.rb`, whose `relates_to :group, Group` re-enters a
  # half-defined `Group` that then inspects a half-defined `Membership`. The
  # forum hit exactly this. Names break the cycle.
  #
  # So the checks — the child is a concrete entity, it declares `via` towards
  # this entity, and for `has_one` that relationship is `unique: true` — run
  # **on the first read** of the association (once per class), and **at boot
  # when `config.eager_load` is on** (the Railtie), so production fails to
  # start rather than at the first request. Call {#validate_inverses!} to run
  # them whenever you like. This is RFC-0015's declaration-time raise, moved to
  # the earliest moment that is safe under autoloading.
  #
  # ## What you get, and what you don't (honestly)
  #
  # - `<<` and `create!` write the link row immediately, with `slot`,
  #   `owner_model` and `exclusive` preset by the link scope and the
  #   Relationship's own before_save. **`build` writes it when the parent
  #   saves**, as with any `has_many :through`; a built child that saves itself
  #   first is not linked. For `has_one`, assignment and `create_x!` link
  #   immediately (the latter flushes the join record Rails would otherwise
  #   leave for the owner's save); `build_x` links on the owner's save.
  # - `dependent:` applies to the **link rows** only (`:destroy` or
  #   `:delete_all`): destroying the parent then removes its pointers rather
  #   than leaving them nullified by the foreign key. Destroying the child
  #   *entities* stays an explicit domain choice.
  # - No counter cache (`counter_cache` is belongs_to-only). A cached count is
  #   a `Counter` slot plus callbacks.
  #
  # Both macros keep their ActiveRecord meaning when called without `via:` — the
  # DSL's own slot-scoped `has_one` for component readers goes through here
  # untouched.
  module Inverses
    # One recorded inverse, by class NAME (reload-safe, like the registry).
    #
    # @!attribute [rw] name
    #   @return [Symbol] the reader, e.g. `:comments`
    # @!attribute [rw] macro
    #   @return [Symbol] `:has_many` or `:has_one`
    # @!attribute [rw] child_class_name
    #   @return [String] the entity that owns the link, e.g. `"Comment"`
    # @!attribute [rw] via
    #   @return [Symbol] the child's relationship name, e.g. `:post`
    InverseMeta = Struct.new(:name, :macro, :child_class_name, :via) do
      # @return [Class<EcsRails::Entity>]
      # @raise [NameError] if no such constant
      def child_class
        child_class_name.constantize
      end

      # @return [Symbol] the link association's name — `:comments_post_links`
      #   for a has_many, `:invoice_order_link` for a has_one
      def link_name
        macro == :has_many ? :"#{name}_#{via}_links" : :"#{name}_#{via}_link"
      end
    end

    # Instance-side helpers, included into EcsRails::Entity.
    module Entity
      # Every relationship row pointing at this entity, under any name — the
      # Flecs `(*, target)` wildcard the shared table makes expressible
      # (RFC-0015). A query, not an association: what a safe-destroy check or an
      # orphan audit wants.
      #
      # @example
      #   user.referrers.pluck(:owner_model, :slot)   # => [["posts", "author"], ...]
      #   user.referrers(slot: :author).count
      #
      # @param slot [Symbol, String, nil] restrict to one relationship name
      # @return [ActiveRecord::Relation] Relationship rows
      def referrers(slot: nil)
        scope = EcsRails.config.relationship_class_name.constantize.where(target_id: id)
        slot.nil? ? scope : scope.where(slot: slot.to_s)
      end
    end

    # Declares a collection of the entities whose `via` relationship points at
    # this one — or, without `via:`, ActiveRecord's own `has_many`.
    #
    # @example
    #   has_many :comments, via: :post                       # child inferred: Comment
    #   has_many :replies, "Comment", via: :parent           # child named
    #   has_many :comments, via: :post, dependent: :destroy  # destroy the link rows too
    #
    # @param name [Symbol] the reader
    # @param child [Class<EcsRails::Entity>, String, Proc, nil] the child entity,
    #   as a class or class name; inferred from `name` when omitted. Without
    #   `via:`, ActiveRecord's optional scope.
    # @param via [Symbol, nil] the child's `relates_to` name
    # @param dependent [Symbol, nil] `:destroy` or `:delete_all` — for the link
    #   rows, never the children
    # @param options [Hash] ActiveRecord's options, when `via:` is absent
    # @return [void]
    # @raise [EcsRails::DelegationConflict] if `name` is already taken
    # @raise [ArgumentError] for a bad `child` or `dependent:`
    # @see #has_one
    # @see #validate_inverses!
    def has_many(name, child = nil, via: nil, dependent: nil, **options, &block)
      return super(name, child, **options, &block) if via.nil? && !child.is_a?(Class)

      define_inverse(:has_many, name, child, via, dependent)
    end

    # Declares the single entity whose `via` relationship points at this one —
    # or, without `via:`, ActiveRecord's own `has_one`.
    #
    # The child's relationship must be `unique: true`: that is what makes "at
    # most one" a database guarantee (ADR-0017's partial unique index), and a
    # `has_one` that could silently return one of several rows is refused —
    # on first use, or at boot under `eager_load` (ADR-0004's ethos, at the
    # earliest safe moment).
    #
    # @example
    #   has_one :invoice, via: :order
    #
    # @param name [Symbol] the reader
    # @param child [Class<EcsRails::Entity>, String, Proc, nil] as for {#has_many}
    # @param via [Symbol, nil] the child's `relates_to` name
    # @param dependent [Symbol, nil] `:destroy` or `:delete_all` — for the link row
    # @param options [Hash] ActiveRecord's options, when `via:` is absent
    # @return [void]
    # @raise [EcsRails::DelegationConflict] if `name` is already taken
    # @raise [ArgumentError] for a bad `child` or `dependent:`
    # @see #has_many
    def has_one(name, child = nil, via: nil, dependent: nil, **options, &block)
      return super(name, child, **options, &block) if via.nil? && !child.is_a?(Class)

      define_inverse(:has_one, name, child, via, dependent)
    end

    # The inverses declared on this entity, ancestry included.
    #
    # @return [Array<InverseMeta>]
    def inverses
      entity_ancestry.flat_map { |klass| (klass.instance_variable_get(:@ecs_inverses) || {}).values }
    end

    # @param name [Symbol, String]
    # @return [InverseMeta, nil]
    def inverse_meta(name)
      inverses.find { |meta| meta.name == name.to_sym }
    end

    # Checks every inverse declared on this entity against its child: the child
    # is a concrete entity, it declares `via` towards this entity, and for a
    # `has_one` that relationship is `unique: true`. Runs automatically on the
    # first read of each association and at boot under `eager_load`; call it
    # yourself to fail earlier.
    #
    # @return [void]
    # @raise [EcsRails::InvalidRelationship] naming the exact `relates_to` line to write
    def validate_inverses!
      inverses.each { |meta| validate_inverse!(meta.name) }
    end

    # Checks one inverse, once per class.
    #
    # @param name [Symbol]
    # @return [void]
    # @raise [EcsRails::InvalidRelationship]
    # @api private
    def validate_inverse!(name)
      validated = (@ecs_validated_inverses ||= {})
      return if validated[name]

      meta = inverse_meta(name) or return
      validate_inverse_pair!(meta)
      validated[name] = true
    end

    private

    # ActiveRecord's own macros, reached by binding rather than `super` because
    # the has_one expansion needs has_many for its link.
    AR_HAS_MANY = ActiveRecord::Associations::ClassMethods.instance_method(:has_many)
    AR_HAS_ONE = ActiveRecord::Associations::ClassMethods.instance_method(:has_one)
    private_constant :AR_HAS_MANY, :AR_HAS_ONE

    def define_inverse(macro, name, child, via, dependent)
      name = name.to_sym
      raise ArgumentError, "#{macro} :#{name} on #{self.name}: an entity child needs `via:` — the child's " \
                           "relates_to name, e.g. `#{macro} :#{name}, via: :owner`" if via.nil?

      via = via.to_sym
      child_name = inverse_child_name(macro, name, child)
      validate_dependent!(name, dependent)
      detect_inverse_collision!(name)

      meta = InverseMeta.new(name, macro, child_name, via)
      slot = via.to_s
      link_macro = macro == :has_many ? AR_HAS_MANY : AR_HAS_ONE
      link_options = { class_name: EcsRails.config.relationship_class_name, foreign_key: :target_id,
                       inverse_of: :target }
      link_options[:dependent] = dependent if dependent

      # owner_model is read inside the lambda, at query time, so the child is
      # resolved then and never at class-load time (see the module comment).
      link_macro.bind_call(self, meta.link_name,
                           -> { where(slot: slot, owner_model: meta.child_class.model_name.collection) },
                           **link_options)
      link_macro.bind_call(self, name, through: meta.link_name, source: :entity, class_name: child_name)

      (@ecs_inverses ||= {})[name] = meta
      define_inverse_guards(meta)
    end

    # The child as a class name: a Class gives its name (and is checked now to be
    # an entity — a Component here is a mistake we can see immediately), a
    # String or Symbol is taken as given, nil infers from the reader
    # (`:comments` → "Comment").
    def inverse_child_name(macro, name, child)
      case child
      when nil then name.to_s.singularize.camelize
      when String, Symbol then child.to_s
      when Class
        unless child < EcsRails::Entity && !child.abstract_class?
          raise InvalidRelationship,
                "#{macro} :#{name} on #{self.name} expected an entity as the child, got #{child.name}. " \
                "Write `#{macro} :#{name}, via: :#{name.to_s.singularize}` and let the child be inferred, " \
                "or name an entity class."
        end
        child.name
      else
        raise ArgumentError, "#{macro} :#{name}: the child must be an entity class or a class name, got #{child.inspect}"
      end
    end

    # The first read of the association (and, for has_one, its build/create
    # forms) validates the pair once. Defined into generated_component_methods,
    # which sits in front of ActiveRecord's generated association methods, so
    # `super` reaches the real association.
    #
    # `create_invoice` / `create_invoice!` also save the link row. ActiveRecord's
    # has_one :through builds the join record on create and leaves it for the
    # owner's next save — `club.create_invoice!` would otherwise return a saved
    # Invoice whose `team` is nil until `club.save!`. Flushing the freshly built
    # link here makes the method mean what it says; assignment
    # (`club.invoice = invoice`) already links immediately.
    def define_inverse_guards(meta)
      mod = generated_component_methods
      name = meta.name
      link_name = meta.link_name

      mod.define_method(name) do |*args, **kwargs, &block|
        self.class.validate_inverse!(name)
        super(*args, **kwargs, &block)
      end
      return unless meta.macro == :has_one

      mod.define_method(:"build_#{name}") do |*args, **kwargs, &block|
        self.class.validate_inverse!(name)
        super(*args, **kwargs, &block)
      end

      [:"create_#{name}", :"create_#{name}!"].each do |method|
        mod.define_method(method) do |*args, **kwargs, &block|
          self.class.validate_inverse!(name)
          record = super(*args, **kwargs, &block)
          link = association(link_name).target
          link.save! if record.persisted? && link&.new_record?
          record
        end
      end
    end

    # The child must be a concrete entity that relates `via` to THIS entity (or
    # an ancestor of it — a subclass reads its parent's inverses), and for
    # has_one that relationship must be unique.
    def validate_inverse_pair!(meta)
      macro, name, via = meta.macro, meta.name, meta.via
      child = begin
        meta.child_class
      rescue NameError
        raise InvalidRelationship,
              "#{macro} :#{name} on #{self.name}: no entity class named #{meta.child_class_name}. " \
              "Name the child — `#{macro} :#{name}, \"TheClass\", via: :#{via}` — or define it."
      end

      unless child.is_a?(Class) && child < EcsRails::Entity && !child.abstract_class?
        raise InvalidRelationship,
              "#{macro} :#{name} on #{self.name}: #{meta.child_class_name} is not a concrete entity."
      end

      rel = child.relationship_meta(via)
      unless rel
        known = child.relationship_names
        raise InvalidRelationship,
              "#{macro} :#{name} on #{self.name}: #{child.name} has no relationship :#{via} " \
              "(#{child.name} relates to: #{known.empty? ? 'none' : known.map { |n| ":#{n}" }.join(', ')}). " \
              "Declare `relates_to :#{via}, #{self.name}` on #{child.name} first."
      end

      unless self <= rel.target_class
        raise InvalidRelationship,
              "#{macro} :#{name} on #{self.name}: #{child.name} relates :#{via} to " \
              "#{rel.target_class_name}, not to #{self.name}."
      end

      return unless macro == :has_one && !rel.unique

      raise InvalidRelationship,
            "has_one :#{name} on #{self.name} needs #{child.name}'s relationship :#{via} to be " \
            "declared `unique: true` — only the database's partial unique index makes \"at most one\" " \
            "true. Write `relates_to :#{via}, #{self.name}, unique: true` on #{child.name}, or use has_many."
    end

    def validate_dependent!(name, dependent)
      return if dependent.nil? || %i[destroy delete_all].include?(dependent)

      raise ArgumentError,
            "has_many/has_one :#{name}: dependent: applies to the link rows and accepts :destroy or " \
            ":delete_all; got #{dependent.inspect}. Destroying child entities is a domain choice."
    end

    # The names an inverse reserves on the entity, for the DSL's conflict
    # checks (EcsRails::DSL#ecs_reserved_names): a later component may not
    # delegate `comments`, and a marker may not be named `comments`.
    def ecs_reserved_names
      inverses.each_with_object(super) do |meta, reserved|
        [meta.name, :"#{meta.name}=", :"#{meta.name.to_s.singularize}_ids",
         :"#{meta.name.to_s.singularize}_ids=", meta.link_name].each do |method|
          reserved[method] ||= "#{meta.macro} :#{meta.name}"
        end
      end
    end

    # ADR-0004: the reader must not be a name the entity already answers.
    def detect_inverse_collision!(name)
      taken = component_declarations.flat_map do |declaration|
        [declaration.reader_name, :"#{declaration.reader_name}?"] + delegation_map_for(declaration).keys
      end
      taken += ecs_reserved_names.keys

      return unless taken.include?(name)

      raise DelegationConflict,
            "has_many/has_one :#{name} on #{self.name} collides with an existing ##{name} — a component, " \
            "a relationship, a marker or another inverse already owns that name. Choose a different name."
    end
  end
end
