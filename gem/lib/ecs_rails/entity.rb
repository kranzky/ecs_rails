# frozen_string_literal: true

module EcsRails
  # An immutable identity row. Carries no domain state.
  #
  # Implements RFC-0001. See docs/architecture.md §1 for the invariants and
  # docs/adr/0002-single-entities-table.md for why the `model` column exists.
  #
  # Host apps subclass this once, as ApplicationEntity, then subclass that per
  # entity type:
  #
  #   class ApplicationEntity < EcsRails::Entity
  #     self.abstract_class = true
  #   end
  #
  #   class User < ApplicationEntity
  #   end
  #
  #   User.create!.model  # => "users"
  #   User.all            # => SELECT * FROM entities WHERE model = 'users'
  #   ApplicationEntity.all # => SELECT * FROM entities  (no filter)
  #
  # All entity classes share the one `entities` table. There is no updated_at
  # column: an entity is written once and never changes, so ActiveRecord's
  # timestamp code — which only touches timestamp columns that actually exist —
  # stamps created_at and nothing else. No configuration is needed for that.
  class Entity < ActiveRecord::Base
    # Makes assignment to a readonly attribute raise on a persisted record.
    #
    # ActiveRecord ships this behaviour, but `attr_readonly` only installs it
    # when `ActiveRecord.raise_on_assign_to_attr_readonly` is true. That config
    # defaults to *false* in bare ActiveRecord, and in a Rails app it is applied
    # by the railtie only after this file has already been required — so by the
    # time `attr_readonly` runs below, the host's setting is not yet visible and
    # cannot be relied on either way. RFC-0001 requires the raise
    # unconditionally, so we install our own guard rather than inherit a race.
    #
    # Harmless if ActiveRecord's own guard is also installed: both raise the
    # same error.
    module ImmutableIdentity
      # Rejects writes to readonly attributes once the row exists. New records
      # are untouched, so create — including ActiveRecord assigning the
      # database-generated id — still works.
      #
      # Both writers are guarded because the public #write_attribute does not
      # call #_write_attribute; it writes to the attribute set directly.
      def write_attribute(attr_name, value)
        guard_readonly_attribute!(attr_name)
        super
      end

      # The internal writer, which every generated `attr=` method funnels into.
      def _write_attribute(attr_name, value)
        guard_readonly_attribute!(attr_name)
        super
      end

      private

      def guard_readonly_attribute!(attr_name)
        return if new_record?
        return unless self.class.readonly_attributes.include?(attr_name.to_s)

        raise ActiveRecord::ReadonlyAttributeError, attr_name
      end
    end

    self.abstract_class = true
    self.table_name = "entities"

    include ImmutableIdentity

    # Lazy / virtual components (RFC-0006): the memo behind every component
    # reader, and the save cascade. The readers themselves are generated per
    # component by the DSL, into generated_component_methods.
    include Lazy::Entity

    # Validation error merging (RFC-0007): the `validate` callback that reflects
    # a dirty component's validity onto the entity, and the human_attribute_name
    # override that keeps `errors[:"email.address"]` machine-readable while
    # `full_messages` reads "Email address is invalid". Included after
    # Lazy::Entity because it walks Lazy's memo (@ecs_components).
    include Validations::Entity

    # The `component` DSL (RFC-0004). Extended rather than defined here: RFC-0001
    # is about identity, and composition is a separate concern with its own file.
    # Singleton methods are inherited, so every entity subclass answers it.
    extend DSL

    # Immutable identity (architecture.md §1). Beyond the guard above, this is
    # what excludes id and model from any UPDATE statement.
    attr_readonly :id, :model

    # Filters each concrete subclass to its own discriminator.
    #
    # `default_scope` is the right mechanism here despite its usual reputation,
    # for two reasons:
    #
    # 1. `build_default_scope` returns early for abstract classes, so the
    #    abstract base applies no filter and can query across all entities —
    #    exactly what RFC-0001 asks for, with no special-casing from us.
    # 2. The block is instance_exec'd against the relation, so `klass` is
    #    whichever class is being queried. One declaration here covers every
    #    subclass, and a subclass of a subclass filters on its own plural.
    #
    # Its notorious leak into `new`/`create` is, unusually, wanted: scope_for_create
    # means `User.new.model` is already "users" before save. That leak is a
    # convenience, not the mechanism — #stamp_model below is what guarantees the
    # discriminator is correct.
    #
    # Must use the same derivation as #stamp_model, or entities become
    # unfindable by the very scope that is supposed to select them.
    default_scope { where(model: klass.model_name.collection) }

    # RFC-0001: model is set on create from the subclass's model_name.collection.
    #
    # Deliberately not left to the default scope's scope_for_create. The
    # discriminator is derived from the class, never supplied by the caller, so
    # it is stamped unconditionally: `User.create!(model: "posts")` yields a
    # user, and `User.unscoped.create!` — which has no create scope to inherit —
    # is still stamped rather than failing the NOT NULL constraint.
    before_validation :stamp_model, on: :create

    class << self
      # Both hooks are private in ActiveRecord, and both are only ever called
      # with an implicit receiver from within AR's own class methods. Matching
      # that visibility keeps them out of the gem's public surface.
      private

      # Resolves a row's `model` discriminator back to the entity subclass that
      # wrote it, so ApplicationEntity.find(id) returns a User. See ADR-0008.
      #
      # This is Rails' own STI resolution hook, applied to a column that is not
      # `inheritance_column` — taking the one piece of machinery we want and
      # none of the rest.
      #
      # Raises NameError for a discriminator that names no live constant (class
      # deleted or renamed). ADR-0008 chooses this deliberately: it matches the
      # registry's fail-loudly stance, and a silent nil would hand back a
      # useless abstract instance.
      #
      # Note this is only ever reached via #instantiate_instance_of below — see
      # the comment there for why the hook alone is not enough.
      def discriminate_class_for_record(record)
        model = record["model"]
        return super if model.blank?

        model.classify.constantize
      rescue NameError => e
        raise NameError, "EcsRails: entity row has model #{model.inspect}, " \
                         "which does not resolve to a class (#{e.message}). " \
                         "See ADR-0008.", e.backtrace
      end

      # Routes every read path through #discriminate_class_for_record.
      #
      # ADR-0008 says to override #discriminate_class_for_record and stop. That
      # is not sufficient on its own: ActiveRecord only consults the hook when
      # the result set contains the *inheritance_column*. From
      # ActiveRecord::Querying#_load_from_sql (8.1):
      #
      #   if result_set.includes_column?(inheritance_column)
      #     rows.map { |r| instantiate(r, ...) }          # calls the hook
      #   else
      #     rows.map { |r| instantiate_instance_of(self, r, ...) }  # does not
      #   end
      #
      # `inheritance_column` is "type", and `entities` has no such column, so
      # entities always take the second branch and the hook is never called.
      # Setting `inheritance_column = "model"` opens the gate but drags in the
      # rest of STI — a type_condition that breaks sub-subclass scoping, and
      # subclass_from_attributes, which turns User.create!(model: "posts") into
      # a SubclassNotFound. Both are behaviours RFC-0001 has already specified
      # otherwise, and both are exactly why ADR-0008 rejected Option B.
      #
      # Overriding here instead keeps #discriminate_class_for_record as the one
      # decision point and leaves inheritance_column alone. Both callers of
      # this method funnel through it — the fast path above, and #instantiate
      # (which the eager-loading path uses) — so every read resolves, and the
      # double call from #instantiate is idempotent.
      def instantiate_instance_of(klass, attributes, column_types = {}, &block)
        super(discriminate_class_for_record(attributes), attributes, column_types, &block)
      end
    end

    private

    # Stamps the model discriminator from the class name. See ADR-0002, and
    # ADR-0008 for why this is #collection and not #plural.
    #
    # #plural is lossy for namespaced classes: Blog::Post and BlogPost both give
    # "blog_posts", so the mapping is not injective and no inverse can separate
    # them — such an entity could be written but never read back as itself.
    # #collection gives "blog/posts", which classifies cleanly back to
    # Blog::Post, and is identical to #plural for every non-namespaced class
    # ("users" either way) — so this needs no data migration.
    #
    # #default_scope above must use the same derivation.
    def stamp_model
      self.model = self.class.model_name.collection
    end
  end
end
