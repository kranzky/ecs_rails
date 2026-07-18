# frozen_string_literal: true

module EcsRails
  # Lazy / virtual components: a component costs nothing until it holds
  # something.
  #
  # Implements RFC-0006 and closes the gap RFC-0004 knowingly left in
  # architecture.md §3 — `entity.email` now always returns an Email.
  #
  #   user = User.create!          # one INSERT, into entities. Nothing else.
  #   user.email                   # => #<Email address: nil, verified: false>
  #   user.email.persisted?        # => false        — no row, and none wanted
  #   user.save!                   # still no emails row
  #
  #   user.email.address = "a@b.com"
  #   user.save!                   # *now* one INSERT into emails
  #
  # The whole feature is two questions: which component instance does the reader
  # hand back (Entity#ecs_component), and does that instance deserve a row
  # (Component#ecs_dirty?). Everything else here is bookkeeping in service of
  # those two.
  module Lazy
    # Mixed into EcsRails::Entity. The reader itself is generated per component
    # by the DSL, into generated_component_methods; this supplies the machinery
    # it calls, and the save cascade.
    module Entity
      extend ActiveSupport::Concern

      included do
        # The cascade (RFC-0006: "entity.save cascades: it saves itself and
        # every dirty component, in one transaction").
        #
        # after_save, not after_create/after_update, because it must run for
        # both — and it does run on an unchanged persisted entity, which matters
        # a great deal here: an entity has no mutable fields of its own
        # (architecture.md §1), so `user.email.address = "x"; user.save!` is
        # *always* a save with nothing of the entity's own to write. If this
        # only fired when the entity itself changed, the money path would never
        # fire at all.
        #
        # ActiveRecord wraps save in a transaction and runs after_save inside
        # it, so "one transaction" needs no work from us.
        after_save :save_dirty_components
      end

      # Drops the memo, so the next read goes back to the database.
      #
      # ActiveRecord's #reload clears the association cache; the memo is a
      # second cache over the same rows and has to be cleared with it or reload
      # would be a lie — the caller would get their stale virtual back.
      def reload(*)
        @ecs_components = nil
        super
      end

      # The instance `entity.email` hands back. Called by the readers the DSL
      # generates; the block reaches the has_one reader underneath.
      #
      # Memoised per entity instance, which RFC-0006 requires and the money path
      # depends on: `user.email.address = "x"; user.save!` only works if the
      # instance the caller mutated is the instance the cascade later sees.
      # Reading twice must not throw the first read's assignment away.
      #
      # The memo caches the *row* case too, not just the virtual one. It costs
      # nothing (the association has its own cache, holding the same object) and
      # it means the cascade can simply walk the memo, rather than interrogating
      # ActiveRecord about which associations happen to be loaded.
      #
      # @api private
      def ecs_component(name)
        cache = (@ecs_components ||= {})
        return cache[name] if cache.key?(name)

        cache[name] = yield || ecs_build_component(name)
      end

      # Forgets a component, so the next read rebuilds it as virtual.
      #
      # Public only because a component calls it on its entity, from across the
      # object boundary — unlike #ecs_component, which the generated readers
      # call on themselves.
      #
      # Called by a component's after_destroy (see Lazy::Component). Clearing
      # the memo is not enough on its own: if the row was read through the
      # reader then ActiveRecord's association is *also* holding it, and #super
      # in the generated reader would hand the frozen, destroyed object straight
      # back. Both caches have to go.
      #
      # The association is left marked loaded-with-nil rather than reset,
      # because that is not a guess: the row was just deleted, and a component
      # appears at most once per entity (ADR-0005), so there is provably nothing
      # left to find. Resetting would buy an identical answer for one SELECT.
      #
      # @api private
      def ecs_forget_component(name)
        @ecs_components&.delete(name)
        return unless self.class.reflect_on_association(name)

        association(name).target = nil
      end

      private

      # An in-memory component with every attribute at its default and entity_id
      # set (RFC-0006). The defaults are ActiveRecord's own, read from the
      # column definitions — so a virtual `user.email.address` and a bare
      # `Email.new.address` agree by construction rather than by us copying a
      # list of defaults about.
      def ecs_build_component(name)
        component = self.class.reflect_on_association(name).klass.new
        # Not `component.entity_id = id` — the belongs_to writer also sets the
        # association target, which is what makes `user.email.entity` return
        # this very entity without a query (architecture.md §1: a system reaches
        # the entity via component.entity). A virtual component has no row, so
        # there is nothing for a query to walk back *from*; if the entity is not
        # handed over here it can never be recovered.
        #
        # On a new entity `id` is still nil at this point — the UUID comes back
        # from the INSERT. #save_dirty_components restamps the foreign key after
        # the entity is saved, which is where that resolves.
        component.entity = self
        component
      end

      # Saves every dirty component the caller has touched, inside the
      # transaction ActiveRecord has already opened around #save.
      #
      # Walks the memo, not the declared components: an untouched component was
      # never read, has no instance, and must not be queried for. That absence
      # is the feature — "components are free unless you use them" is a claim
      # about SQL, and this method is where it is kept.
      def save_dirty_components
        return unless @ecs_components

        @ecs_components.each_value do |component|
          # Destroyed through the reader inside this same save. Saving it would
          # resurrect the row the caller just asked to be rid of.
          next if component.destroyed?
          next unless component.ecs_dirty?

          # The entity's UUID is assigned by the database, so on create it did
          # not exist when the component was built. Restamped rather than
          # assumed. Deliberately after the dirty check, which ignores entity_id
          # for exactly this reason.
          component.entity_id = id

          # Bang, so a failure is loud. This is a deliberate, temporary wart:
          # non-bang `entity.save` will raise RecordInvalid rather than return
          # false when a dirty component is invalid.
          #
          # The alternative is ActiveRecord's own autosave idiom, `raise
          # ActiveRecord::Rollback`. It is worse here. Rollback raised from an
          # after_save is swallowed by the transaction that save itself opened,
          # so `entity.save!` would return nil and raise *nothing at all* — a
          # silent failure to write, which is the one outcome a bang method must
          # never have. (`throw :abort` is not an option either: after_ callbacks
          # cannot halt a chain, and it escapes as an UncaughtThrowError.)
          #
          # RFC-0007 is what fixes this properly: once a dirty component's errors
          # merge onto the entity, `entity.valid?` is false and non-bang `save`
          # returns false before ever reaching this callback — leaving the bang
          # here as belt-and-braces, which is exactly the role the equivalent
          # line plays in ActiveRecord's autosave.
          component.save!
        end
      end
    end

    # Mixed into EcsRails::Component.
    module Component
      extend ActiveSupport::Concern

      included do
        # architecture.md §3: "entity.email.destroy deletes the row and resets
        # the component to its virtual default state. entity.email still returns
        # an instance afterwards."
        #
        # Nothing about destroying a row does that on its own — ActiveRecord
        # leaves the object frozen, still holding the values it had — so the
        # entity has to be told. See #reset_entity_component.
        after_destroy :reset_entity_component
      end

      # Does this component deserve a row?
      #
      # RFC-0006 defines dirty as "at least one attribute differs from its
      # default", explicitly *not* ActiveModel's "differs from the last saved
      # value". Both halves of that matter, and neither is quite what it looks
      # like:
      #
      # 1. ActiveModel's dirty cannot be used for a component with no row.
      #    Building a virtual component sets entity_id, and ActiveModel counts
      #    that as a change — so `user.email.changed?` is true for a component
      #    nobody has touched, and a cascade built on it would insert a row for
      #    every component ever read. That is the whole feature, inverted.
      #
      # 2. RFC-0006's own wording fails for the same reason, taken literally:
      #    entity_id differs from its column default (nil) on every virtual
      #    component too. The foreign key is identity, not state — it says which
      #    entity this is, never anything about it — so the comparison has to
      #    skip it, and the primary key with it. See #state_attribute?.
      #
      # 3. "Differs from default" is only the right question while there is no
      #    row. Once there is one, the question is ActiveModel's, because the
      #    row now has a value to differ *from*: clearing an attribute back to
      #    its default is an UPDATE, and answering "not dirty" would silently
      #    discard it. This is where the two definitions genuinely part company,
      #    and the RFC's destroy-then-reset case is the same split seen from the
      #    other side.
      def ecs_dirty?
        return changed? if persisted?

        self.class.column_defaults.any? do |attribute, default|
          next false unless state_attribute?(attribute)

          read_attribute(attribute) != default
        end
      end

      private

      # Attributes that say something about the component, as opposed to which
      # component it is. Only these can make it dirty.
      def state_attribute?(attribute)
        attribute != self.class.primary_key && attribute != "entity_id"
      end

      # Tells the owning entity to forget this component, so its reader reverts
      # to a virtual one (architecture.md §3).
      #
      # Reads the association target rather than calling #entity, so a component
      # destroyed without its entity loaded — `Email.first.destroy` — costs no
      # query and simply has nobody to notify. Nothing is reset on *this*
      # object: ActiveRecord freezes a destroyed record, and the entity is going
      # to hand out a fresh instance anyway.
      def reset_entity_component
        owner = association(:entity).target
        return unless owner.is_a?(EcsRails::Entity)

        owner.ecs_forget_component(model_name.singular.to_sym)
      end
    end
  end
end
