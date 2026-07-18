# frozen_string_literal: true

# The test schema. Mirrors docs/architecture.md §2.
#
# Every component table here follows the same invariants the generator
# (RFC-0008) will enforce: UUID PK, non-null entity_id with a UNIQUE index and
# an ON DELETE CASCADE FK, and an explicit default for every attribute.

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
    t.string  :address,   default: nil
    t.boolean :verified,  default: false, null: false
    t.timestamps
  end

  create_table :names, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :first,     default: nil
    t.string :last,      default: nil
    t.string :title,     default: nil
    t.timestamps
  end

  create_table :groups, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id,   null: false
    t.string :title,       default: nil
    t.string :description, default: nil
    t.timestamps
  end

  create_table :avatars, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :url,       default: nil
    t.timestamps
  end

  # A relationship component (ADR-0006): holds a UUID pointing at another entity.
  # Its `belongs_to` name collides with its own reader — see the "reader
  # collision" specs in delegation_spec.rb. Surfaced by the demo.
  create_table :sponsors, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
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
    t.timestamps
  end

  # A stateful component that is deliberately *not* declared on any test entity,
  # so `user.add(PublishState)` exercises RFC-0009's InvalidComponent path.
  create_table :publish_states, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid   :entity_id, null: false
    t.string :state,     default: nil
    t.timestamps
  end

  %i[emails names groups avatars sponsors moderators publish_states].each do |table|
    add_index table, :entity_id, unique: true
    add_foreign_key table, :entities, column: :entity_id, on_delete: :cascade
  end
end
