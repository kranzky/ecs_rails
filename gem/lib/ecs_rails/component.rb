# frozen_string_literal: true

module EcsRails
  # An ordinary ActiveRecord model that belongs to exactly one entity.
  #
  # Implements RFC-0003. See docs/architecture.md §1 for the invariants.
  #
  # Host apps subclass this once, as ApplicationComponent, then subclass that
  # per component type:
  #
  #   class ApplicationComponent < EcsRails::Component
  #     self.abstract_class = true
  #   end
  #
  #   class Email < ApplicationComponent
  #     validates :address, presence: true
  #   end
  #
  #   Email.where(verified: false)  # queried directly; no join to entities
  #   Email.first.entity            # => #<User> — the real subclass (ADR-0008)
  #
  # A component owns its own table and knows nothing about entity subclasses.
  # Scopes, validations, callbacks and associations all work as normal: this is
  # a plain AR model that happens to hang off an entity.
  #
  # Relationship target types are supplied by the owner's declaration as slot
  # options; the shared Relationship component does not name domain classes
  # (ADR-0017).
  class Component < ActiveRecord::Base
    self.abstract_class = true

    # Lazy / virtual components (RFC-0006), from the component's side: what
    # "dirty" means — the question that decides whether this component is worth
    # a row — and the after_destroy that resets its entity's reader back to a
    # virtual instance (architecture.md §3).
    include Lazy::Component

    # Labelled components (RFC-0014 / ADR-0015), from the component's side: the
    # slot-aware reader name, and the `slot_option` DSL through which a
    # declaration site configures this component per slot.
    include Slots::Component

    # Every component belongs to exactly one entity (architecture.md §1).
    #
    # The association targets the abstract ApplicationEntity, which has no table
    # of its own — but EcsRails::Entity sets table_name to "entities", so the
    # generated query is an ordinary select against that table. The loaded row's
    # `model` column then decides which subclass to instantiate, via
    # Entity.instantiate_instance_of (ADR-0008's amendment). This makes `email.entity`
    # return a User rather than an ApplicationEntity (RFC-0003, ADR-0008).
    #
    # The owner is required, but the requirement is written out below rather
    # than left to `optional: false` (RFC-0003's ECS-47 amendment). Rails
    # builds a required belongs_to's validator from two host settings, both
    # applied by the railtie via load_defaults: `belongs_to_required_by_default`
    # and, since 7.1, `belongs_to_required_validates_foreign_key`. Both are read
    # once, when `belongs_to` runs — and this line runs when the gem is
    # required, before any host's defaults apply. So `optional: false` always
    # got the pre-7.1 validator, which loads the owner on every save even when
    # entity_id did not change: one SELECT per update of a component loaded on
    # its own (`Counter.where(...).lock`, `Email.find(id).update!`).
    #
    # Hence `optional: true` (no validator from Rails) plus the 7.1 rule stated
    # here: check the owner when entity_id is nil or changed. That is the same
    # in every host, as RFC-0003 wants (the reasoning of RFC-0001's readonly
    # guard in entity.rb), and the skipped read guards nothing: every component
    # table's entity_id is a foreign key to entities(id) with ON DELETE
    # CASCADE, so an unchanged key cannot point at a missing entity.
    #
    # Deliberately no `dependent:` option. Cascade is owned by the database:
    # every component table has an ON DELETE CASCADE foreign key to
    # entities(id), so entity.destroy removes the component rows
    # (architecture.md §3). Declaring `dependent: :destroy` on this side would
    # invert the ownership — destroying a component would destroy its entity,
    # and with it every sibling component. That is the wrong direction and
    # destructive; the DB layer already has the right one.
    belongs_to :entity, class_name: "ApplicationEntity", optional: true
    validates :entity, presence: { message: :required },
                       if: -> { entity_id.nil? || entity_id_changed? }

    # The unique index on (entity_id, slot) (ADR-0005, generalised by ADR-0015)
    # is the real enforcement, and a uniqueness validation here would cost a
    # SELECT on every save while still racing. RFC-0003 asserts RecordNotUnique
    # from the database, so the guard is left where it is enforced.
  end
end
