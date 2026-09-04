# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_04_080008) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "addresses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "country", limit: 2
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "line1"
    t.string "line2"
    t.string "locality"
    t.string "postcode"
    t.string "region"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_addresses_on_entity_id_and_slot", unique: true
  end

  create_table "calendar_dates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date"
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_calendar_dates_on_entity_id_and_slot", unique: true
  end

  create_table "counters", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_counters_on_entity_id_and_slot", unique: true
  end

  create_table "discards", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_discards_on_entity_id_and_slot", unique: true
  end

  create_table "emails", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "address"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false, null: false
    t.index ["entity_id", "slot"], name: "index_emails_on_entity_id_and_slot", unique: true
  end

  create_table "entities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "model", null: false
    t.index ["model"], name: "index_entities_on_model"
  end

  create_table "geolocations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "geocoded_at"
    t.decimal "lat", precision: 10, scale: 7
    t.decimal "lng", precision: 10, scale: 7
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_geolocations_on_entity_id_and_slot", unique: true
  end

  create_table "identifiers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["entity_id", "slot"], name: "index_identifiers_on_entity_id_and_slot", unique: true
    t.index ["slot", "value"], name: "index_identifiers_on_slot_and_value", unique: true
  end

  create_table "images", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "alt"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["entity_id", "slot"], name: "index_images_on_entity_id_and_slot", unique: true
  end

  create_table "links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "label"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["entity_id", "slot"], name: "index_links_on_entity_id_and_slot", unique: true
  end

  create_table "markers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_markers_on_entity_id_and_slot", unique: true
  end

  create_table "monies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "amount_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "currency", limit: 3, default: "USD", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_monies_on_entity_id_and_slot", unique: true
  end

  create_table "names", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "family"
    t.string "full"
    t.string "given"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_names_on_entity_id_and_slot", unique: true
  end

  create_table "passwords", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "password_digest"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_passwords_on_entity_id_and_slot", unique: true
  end

  create_table "periods", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "all_day", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "ends_at"
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "starts_at"
    t.string "time_zone"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_periods_on_entity_id_and_slot", unique: true
  end

  create_table "phones", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "e164", limit: 16
    t.uuid "entity_id", null: false
    t.string "extension", limit: 8
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_phones_on_entity_id_and_slot", unique: true
  end

  create_table "positions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.integer "position", default: 0, null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_positions_on_entity_id_and_slot", unique: true
    t.index ["slot", "position"], name: "index_positions_on_slot_and_position"
  end

  create_table "ratings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.integer "stars"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_ratings_on_entity_id_and_slot", unique: true
  end

  create_table "relationships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.boolean "exclusive", default: false, null: false
    t.string "owner_model", null: false
    t.string "slot", default: "", null: false
    t.uuid "target_id"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_relationships_on_entity_id_and_slot", unique: true
    t.index ["target_id", "slot", "owner_model"], name: "index_relationships_exclusive", unique: true, where: "exclusive"
    t.index ["target_id", "slot"], name: "index_relationships_on_target_id_and_slot"
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "name"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_roles_on_entity_id_and_slot", unique: true
  end

  create_table "search_vectors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.tsvector "document"
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["document"], name: "index_search_vectors_on_document", using: :gin
    t.index ["entity_id", "slot"], name: "index_search_vectors_on_entity_id_and_slot", unique: true
  end

  create_table "states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.string "status"
    t.jsonb "transitions", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_states_on_entity_id_and_slot", unique: true
  end

  create_table "tags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "names", default: [], null: false, array: true
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_tags_on_entity_id_and_slot", unique: true
    t.index ["names"], name: "index_tags_on_names", using: :gin
  end

  create_table "texts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["entity_id", "slot"], name: "index_texts_on_entity_id_and_slot", unique: true
  end

  create_table "timestamps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "at"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_timestamps_on_entity_id_and_slot", unique: true
  end

  create_table "tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "digest"
    t.uuid "entity_id", null: false
    t.datetime "expires_at"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["digest"], name: "index_tokens_on_digest"
    t.index ["entity_id", "slot"], name: "index_tokens_on_entity_id_and_slot", unique: true
  end

  add_foreign_key "addresses", "entities", on_delete: :cascade
  add_foreign_key "calendar_dates", "entities", on_delete: :cascade
  add_foreign_key "counters", "entities", on_delete: :cascade
  add_foreign_key "discards", "entities", on_delete: :cascade
  add_foreign_key "emails", "entities", on_delete: :cascade
  add_foreign_key "geolocations", "entities", on_delete: :cascade
  add_foreign_key "identifiers", "entities", on_delete: :cascade
  add_foreign_key "images", "entities", on_delete: :cascade
  add_foreign_key "links", "entities", on_delete: :cascade
  add_foreign_key "markers", "entities", on_delete: :cascade
  add_foreign_key "monies", "entities", on_delete: :cascade
  add_foreign_key "names", "entities", on_delete: :cascade
  add_foreign_key "passwords", "entities", on_delete: :cascade
  add_foreign_key "periods", "entities", on_delete: :cascade
  add_foreign_key "phones", "entities", on_delete: :cascade
  add_foreign_key "positions", "entities", on_delete: :cascade
  add_foreign_key "ratings", "entities", on_delete: :cascade
  add_foreign_key "relationships", "entities", column: "target_id", on_delete: :nullify
  add_foreign_key "relationships", "entities", on_delete: :cascade
  add_foreign_key "roles", "entities", on_delete: :cascade
  add_foreign_key "search_vectors", "entities", on_delete: :cascade
  add_foreign_key "states", "entities", on_delete: :cascade
  add_foreign_key "tags", "entities", on_delete: :cascade
  add_foreign_key "texts", "entities", on_delete: :cascade
  add_foreign_key "timestamps", "entities", on_delete: :cascade
  add_foreign_key "tokens", "entities", on_delete: :cascade
end
