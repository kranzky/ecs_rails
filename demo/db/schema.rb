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

ActiveRecord::Schema[8.1].define(version: 2026_09_04_042520) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "avatars", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["entity_id", "slot"], name: "index_avatars_on_entity_id_and_slot", unique: true
  end

  create_table "bios", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.text "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_bios_on_entity_id_and_slot", unique: true
  end

  create_table "bodies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.text "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_bodies_on_entity_id_and_slot", unique: true
  end

  create_table "descriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.text "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_descriptions_on_entity_id_and_slot", unique: true
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

  create_table "likes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "count"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_likes_on_entity_id_and_slot", unique: true
  end

  create_table "markers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_markers_on_entity_id_and_slot", unique: true
  end

  create_table "names", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "first"
    t.string "last"
    t.string "slot", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_names_on_entity_id_and_slot", unique: true
  end

  create_table "publish_states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_publish_states_on_entity_id_and_slot", unique: true
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

  create_table "titles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "slot", default: "", null: false
    t.string "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id", "slot"], name: "index_titles_on_entity_id_and_slot", unique: true
  end

  add_foreign_key "avatars", "entities", on_delete: :cascade
  add_foreign_key "bios", "entities", on_delete: :cascade
  add_foreign_key "bodies", "entities", on_delete: :cascade
  add_foreign_key "descriptions", "entities", on_delete: :cascade
  add_foreign_key "emails", "entities", on_delete: :cascade
  add_foreign_key "likes", "entities", on_delete: :cascade
  add_foreign_key "markers", "entities", on_delete: :cascade
  add_foreign_key "names", "entities", on_delete: :cascade
  add_foreign_key "publish_states", "entities", on_delete: :cascade
  add_foreign_key "relationships", "entities", column: "target_id", on_delete: :nullify
  add_foreign_key "relationships", "entities", on_delete: :cascade
  add_foreign_key "roles", "entities", on_delete: :cascade
  add_foreign_key "titles", "entities", on_delete: :cascade
end
