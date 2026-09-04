# frozen_string_literal: true

# The test schema. Mirrors docs/architecture.md §2.
#
# Every component table here follows the same invariants the generator
# (RFC-0008) enforces: UUID PK, non-null entity_id, a `slot` string defaulting
# to "" with a UNIQUE index on (entity_id, slot) (ADR-0005 / ADR-0015), an ON
# DELETE CASCADE FK, and an explicit default for every attribute.

ActiveRecord::Schema.verbose = false

ActiveRecord::Schema.define do
  enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

  create_table :entities, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string :model, null: false, index: true
    t.datetime :created_at, null: false
    # No updated_at — entities are immutable. See RFC-0001.
  end

  # --- test components -------------------------------------------------------

  create_table :emails, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid    :entity_id, null: false
    t.string :slot,     null: false, default: ""
    t.string  :address,   default: nil
    t.boolean :verified,  default: false, null: false
    t.timestamps
  end

  create_table :names, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :slot,     null: false, default: ""
    t.string :first,     default: nil
    t.string :last,      default: nil
    t.string :title,     default: nil
    t.timestamps
  end

  create_table :groups, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id,   null: false
    t.string :slot,        null: false, default: ""
    t.string :title,       default: nil
    t.string :description, default: nil
    # A date, so delegation_spec can prove Rails multiparameter form fields
    # (`date_select` posting `group_founded_on(1i)`…) route through a prefixed
    # delegated writer (ADR-0016 / ECS-12).
    t.date   :founded_on,  default: nil
    t.timestamps
  end

  create_table :avatars, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :slot,     null: false, default: ""
    t.string :url,       default: nil
    t.timestamps
  end

  # A relationship component (ADR-0006): holds a UUID pointing at another entity.
  # Its `belongs_to` name collides with its own reader — see the "reader
  # collision" specs in delegation_spec.rb. Surfaced by the demo.
  create_table :sponsors, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
    t.string :slot,     null: false, default: ""
    t.uuid :sponsor_id, default: nil
    t.timestamps
  end

  # A marker component (ADR-0009 / RFC-0009): no state at all, only entity_id. A
  # user *is* a moderator exactly when a row exists here. This is the shape the
  # demo's Moderator/Administrator take, and the case the lazy save cascade can
  # never persist (a marker is never dirty), so presence must be explicit. Note
  # there is no attribute column: the whole point is that presence is the state.
  create_table :moderators, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
    t.string :slot,     null: false, default: ""
    t.timestamps
  end

  # A stateful component that is deliberately *not* declared on any test entity,
  # so `user.add(PublishState)` exercises RFC-0009's InvalidComponent path.
  create_table :publish_states, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :slot,     null: false, default: ""
    t.string :state,     default: nil
    t.timestamps
  end

  # A naturally multi-role component (RFC-0014 / ADR-0015): one `addresses`
  # table serves the default slot (`user.address`) and every labelled
  # slot (`user.business_address`, `supplier.remit_address`) alike. The `slot`
  # column, present on every component table, is what tells them apart.
  create_table :addresses, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :slot,      null: false, default: ""
    t.string :line1,     default: nil
    t.string :region,    default: nil
    t.string :postcode,  default: nil
    t.timestamps
  end

  # ADR-0005 as generalised by ADR-0015: one row per (entity, slot). The
  # singular case is the `slot = ""` special case of the composite index.
  %i[emails names groups avatars sponsors moderators publish_states addresses].each do |table|
    add_index table, %i[entity_id slot], unique: true
    add_foreign_key table, :entities, column: :entity_id, on_delete: :cascade
  end

  # Tables ADR-0013 used and ADR-0017 retired. A database built by an earlier
  # schema.rb still has them, and the upgrade generator's specs inspect the
  # catalog, so they are dropped explicitly rather than left to linger.
  %i[post_authors comment_authors membership_users membership_teams reloadable_authors].each do |table|
    drop_table table, if_exists: true
  end

  # --- the shared relationships table (ADR-0017) ------------------------------
  #
  # Every `relates_to` in every entity is a row here; the slot is the
  # relationship name. Replaces the per-relationship backing tables ADR-0013
  # generated (post_authors, comment_authors, membership_users, ...). The two
  # foreign keys are asymmetric on purpose: destroying the owner (entity_id)
  # CASCADES and takes the link with it; destroying the target NULLIFIES, so the
  # owner survives with the link cleared. `owner_model` mirrors the owner's
  # entities.model so the exclusivity index is per owner type; `exclusive` is
  # what `relates_to ..., unique: true` writes, and the partial unique index is
  # what enforces it — at most one Invoice per Order — with no index of its own.
  create_table :relationships, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid    :entity_id,   null: false
    t.string  :slot,        null: false, default: ""
    t.uuid    :target_id,   default: nil
    t.string  :owner_model, null: false
    t.boolean :exclusive,   null: false, default: false
    t.timestamps
  end
  add_index :relationships, %i[entity_id slot], unique: true
  add_index :relationships, %i[target_id slot]
  add_index :relationships, %i[target_id slot owner_model], unique: true, where: "exclusive",
                                                             name: "index_relationships_exclusive"
  add_foreign_key :relationships, :entities, column: :entity_id, on_delete: :cascade
  add_foreign_key :relationships, :entities, column: :target_id, on_delete: :nullify
end
