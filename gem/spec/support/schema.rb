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

  %i[emails names groups avatars sponsors].each do |table|
    add_index table, :entity_id, unique: true
    add_foreign_key table, :entities, column: :entity_id, on_delete: :cascade
  end
end
