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

ActiveRecord::Schema[8.1].define(version: 2026_07_21_023014) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "administrators", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_administrators_on_entity_id", unique: true
  end

  create_table "authorships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_authorships_on_entity_id", unique: true
  end

  create_table "avatars", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["entity_id"], name: "index_avatars_on_entity_id", unique: true
  end

  create_table "bios", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.text "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_bios_on_entity_id", unique: true
  end

  create_table "bodies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.text "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_bodies_on_entity_id", unique: true
  end

  create_table "comment_authors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_comment_authors_on_author_id"
    t.index ["entity_id"], name: "index_comment_authors_on_entity_id", unique: true
  end

  create_table "descriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.text "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_descriptions_on_entity_id", unique: true
  end

  create_table "emails", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "address"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false, null: false
    t.index ["entity_id"], name: "index_emails_on_entity_id", unique: true
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
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_likes_on_entity_id", unique: true
  end

  create_table "member_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.uuid "group_id"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_member_groups_on_entity_id", unique: true
  end

  create_table "member_users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["entity_id"], name: "index_member_users_on_entity_id", unique: true
  end

  create_table "membership_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.uuid "group_id"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_membership_groups_on_entity_id", unique: true
    t.index ["group_id"], name: "index_membership_groups_on_group_id"
  end

  create_table "membership_users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["entity_id"], name: "index_membership_users_on_entity_id", unique: true
    t.index ["user_id"], name: "index_membership_users_on_user_id"
  end

  create_table "moderators", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_moderators_on_entity_id", unique: true
  end

  create_table "names", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "first"
    t.string "last"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_names_on_entity_id", unique: true
  end

  create_table "post_authors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_id"
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_post_authors_on_author_id"
    t.index ["entity_id"], name: "index_post_authors_on_entity_id", unique: true
  end

  create_table "publish_states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_publish_states_on_entity_id", unique: true
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_roles_on_entity_id", unique: true
  end

  create_table "titles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "entity_id", null: false
    t.string "text"
    t.datetime "updated_at", null: false
    t.index ["entity_id"], name: "index_titles_on_entity_id", unique: true
  end

  add_foreign_key "administrators", "entities", on_delete: :cascade
  add_foreign_key "authorships", "entities", on_delete: :cascade
  add_foreign_key "avatars", "entities", on_delete: :cascade
  add_foreign_key "bios", "entities", on_delete: :cascade
  add_foreign_key "bodies", "entities", on_delete: :cascade
  add_foreign_key "comment_authors", "entities", column: "author_id", on_delete: :nullify
  add_foreign_key "comment_authors", "entities", on_delete: :cascade
  add_foreign_key "descriptions", "entities", on_delete: :cascade
  add_foreign_key "emails", "entities", on_delete: :cascade
  add_foreign_key "likes", "entities", on_delete: :cascade
  add_foreign_key "member_groups", "entities", on_delete: :cascade
  add_foreign_key "member_users", "entities", on_delete: :cascade
  add_foreign_key "membership_groups", "entities", column: "group_id", on_delete: :nullify
  add_foreign_key "membership_groups", "entities", on_delete: :cascade
  add_foreign_key "membership_users", "entities", column: "user_id", on_delete: :nullify
  add_foreign_key "membership_users", "entities", on_delete: :cascade
  add_foreign_key "moderators", "entities", on_delete: :cascade
  add_foreign_key "names", "entities", on_delete: :cascade
  add_foreign_key "post_authors", "entities", column: "author_id", on_delete: :nullify
  add_foreign_key "post_authors", "entities", on_delete: :cascade
  add_foreign_key "publish_states", "entities", on_delete: :cascade
  add_foreign_key "roles", "entities", on_delete: :cascade
  add_foreign_key "titles", "entities", on_delete: :cascade
end
