# frozen_string_literal: true

module EcsRails
  # Component presence as a first-class operation: add / has? / remove.
  #
  # Implements RFC-0009, decided by ADR-0009. Surfaced by the demo: a marker
  # component (Moderator, Administrator) carries no state, so it is never
  # `ecs_dirty?` (ADR-0003 excludes entity_id as identity), and RFC-0006's save
  # cascade therefore never writes it. The natural path does nothing at all:
  #
  #   user.moderator            # a virtual Moderator
  #   user.save!                # writes no moderators row — a marker is never dirty
  #   user.moderator.persisted? # => false, forever
  #
  # Presence cannot be inferred from lazy state (reading must stay free, RFC-0006)
  # and a marker has nothing to dirty, so presence is its own verb:
  #
  #   user.add(Moderator)     # persist the row now (idempotent, validated)
  #   user.has?(Moderator)    # => true — a row exists
  #   user.moderator?         # => the same question, per-component sugar (DSL)
  #   user.remove(Moderator)  # destroy the row (idempotent)
  #
  # These are useful for *every* component — `has?(Email)`, `remove(Avatar)` —
  # not just empty ones; a marker is simply the case where presence is the only
  # state (ADR-0009). Mirrors Flecs' add/has/remove vocabulary.
  #
  # This module is the entity side. The `<reader>?` predicate is generated per
  # component by the DSL, into generated_component_methods (see
  # EcsRails::DSL#define_component_predicate); it is just `has?(ThatComponent)`.
  module Presence
    module Entity
      extend ActiveSupport::Concern

      # Ensures a row exists for `component_class` on this entity and returns the
      # now-persisted instance (RFC-0009).
      #
      # Immediate, not deferred to the next save: the whole reason `add` exists
      # is that the save cascade never persists a marker. Idempotent: an existing
      # row is returned untouched, never a second INSERT — the unique entity_id
      # index (ADR-0005) would forbid one, and correctness should not depend on
      # catching that. Validated: it uses `save!`, so `add(Email)` raises
      # RecordInvalid (address is required) while `add(Moderator)` always
      # succeeds. You cannot add an empty required component (ADR-0009).
      def add(component_class)
        name = ecs_presence_reader(component_class)

        # The reader goes through RFC-0006's memo. When no row exists on this
        # instance it loads one (a SELECT) or builds a virtual; when a row does
        # exist — including one this instance already added — it is already the
        # persisted instance, so we return it and no second INSERT is attempted.
        component = public_send(name)
        return component if component.persisted?

        # A virtual instance: persist it. entity_id is restamped for the same
        # reason the cascade does (RFC-0006) — on a freshly built virtual for a
        # new entity it may not have been set yet. The memo now holds this same,
        # persisted instance, so a later `entity.moderator` answers from it with
        # no further query.
        component.entity_id = id
        component.save!
        component
      end

      # True iff a row exists for `component_class` on this entity (RFC-0009).
      #
      # Side-effect-free, like `valid?` (RFC-0007): it never materialises,
      # persists, or dirties anything. It consults RFC-0006's memo first — a
      # component dirtied-and-saved on this instance is present without a fresh
      # query — and otherwise issues a bare existence check (SELECT ... EXISTS),
      # a load of nothing.
      def has?(component_class)
        name = ecs_presence_reader(component_class)

        # Memo first: if this instance already loaded (and persisted) the
        # component, the answer is known without touching the database. A merely
        # virtual memo entry is *not* proof of absence — a row could have been
        # written elsewhere — so it falls through to the existence check rather
        # than answering false from memory.
        cached = @ecs_components&.[](name)
        return true if cached&.persisted?

        # Bare existence check: no row is instantiated, so nothing is loaded and
        # nothing is dirtied. One query per component, as everywhere else in the
        # gem (architecture.md §7 non-goal: query optimisation).
        component_class.where(entity_id: id).exists?
      end

      # Destroys the row for `component_class` if present, and resets the reader
      # to a virtual default instance — exactly RFC-0006's `component.destroy`
      # semantics. Idempotent when absent. Returns the entity (RFC-0009).
      def remove(component_class)
        name = ecs_presence_reader(component_class)

        # Reach the component through the reader so a present row is loaded with
        # its callbacks intact. `component.destroy` fires Lazy::Component's
        # after_destroy, which calls #ecs_forget_component here — dropping the
        # memo and nilling the association, so the next read rebuilds a virtual.
        # When nothing is there to destroy the read leaves a virtual in the memo,
        # which is already the reset state, so remove is idempotent.
        component = public_send(name)
        component.destroy if component.persisted?
        self
      end

      private

      # Resolves a declared component class to its reader name, or raises.
      #
      # `add`/`has?`/`remove` accept only a component the entity actually
      # declares (RFC-0009); anything else — an undeclared component, or a class
      # that is not a component at all — is InvalidComponent, checked before any
      # database work. The declared set already accounts for inheritance
      # (DSL#components walks the ancestry), so a subclass sees its parents'
      # components too.
      def ecs_presence_reader(component_class)
        unless self.class.components.include?(component_class)
          raise InvalidComponent,
                "#{component_class.inspect} is not a component of #{self.class.name}"
        end

        component_class.model_name.singular.to_sym
      end
    end
  end
end
