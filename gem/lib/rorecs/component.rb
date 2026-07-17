# frozen_string_literal: true

module Rorecs
  # An ordinary ActiveRecord model that belongs to exactly one entity.
  #
  # Implements RFC-0003. See docs/architecture.md §1 for the invariants.
  #
  # Host apps subclass this once, as ApplicationComponent, then subclass that
  # per component type:
  #
  #   class ApplicationComponent < Rorecs::Component
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
  # The one sanctioned exception to "knows nothing about entity subclasses" is a
  # relationship component's `class_name:` — see ADR-0006.
  class Component < ActiveRecord::Base
    self.abstract_class = true

    # Every component belongs to exactly one entity (architecture.md §1).
    #
    # The association targets the abstract ApplicationEntity, which has no table
    # of its own — but Rorecs::Entity sets table_name to "entities", so the
    # generated query is an ordinary select against that table. The loaded row's
    # `model` column then decides which subclass to instantiate, via
    # Entity.discriminate_class_for_record. That is what makes `email.entity`
    # return a User rather than an ApplicationEntity (RFC-0003, ADR-0008).
    #
    # `optional: false` is explicit rather than inherited from
    # `belongs_to_required_by_default`. That config is applied by the Rails
    # railtie via load_defaults, so its value depends on the host app's
    # configured defaults and is not visible in bare ActiveRecord. RFC-0003
    # requires entity_id to be required unconditionally, so we state it here
    # rather than inherit a host's setting. (Same reasoning as RFC-0001's
    # readonly guard in entity.rb.)
    #
    # Deliberately no `dependent:` option. Cascade is owned by the database:
    # every component table has an ON DELETE CASCADE foreign key to
    # entities(id), so entity.destroy removes the component rows
    # (architecture.md §3). Declaring `dependent: :destroy` on this side would
    # invert the ownership — destroying a component would destroy its entity,
    # and with it every sibling component. That is the wrong direction and
    # destructive; the DB layer already has the right one.
    belongs_to :entity, class_name: "ApplicationEntity", optional: false

    # The unique index on entity_id (ADR-0005) is the real enforcement, and a
    # uniqueness validation here would cost a SELECT on every save while still
    # racing. RFC-0003 asserts RecordNotUnique from the database, so the guard
    # is left where it is enforced.
  end
end
