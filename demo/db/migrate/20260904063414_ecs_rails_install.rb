# frozen_string_literal: true

# The ECS Rails install migration — the last migration this application needs
# to build from the catalogue (ADR-0018).
#
# It creates the single `entities` table every entity shares, and one table per
# catalogue component in the installed sets (core): each with a
# UUID primary key, a non-null `entity_id`, a `slot` label defaulting to "", a
# UNIQUE index on (entity_id, slot) and a cascading foreign key to `entities`
# (docs/architecture.md §2). Declaring a component, a relationship or a marker
# on an entity is then pure Ruby; a slot names the role
# (`component Text, prefix: :title`). `rails g ecs_rails:upgrade` brings the
# tables forward when the gem is upgraded.
#
# Generated from the gem's schema declarations (EcsRails::Catalogue); edit the
# declarations' one-line classes under app/entities/components,
# not this file.
class EcsRailsInstall < ActiveRecord::Migration[8.1]
  def change
    # gen_random_uuid() lives in pgcrypto on PostgreSQL < 13; enabling it is
    # harmless on 13+, where the function is built in.
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    create_table :entities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # The entity subclass discriminator, e.g. "users". Indexed because
      # User.all compiles to WHERE model = 'users'.
      t.string :model, null: false, index: true
      t.datetime :created_at, null: false
      # No updated_at — an entity is written once and never changes.
      # See RFC-0001 and docs/architecture.md §1.
    end

    # Relationship (core) — EcsRails::Catalogue::Relationship
    create_table :relationships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.uuid :target_id, default: nil
      t.string :owner_model, null: false
      t.boolean :exclusive, default: false, null: false
      t.timestamps
    end
    add_index :relationships, [:entity_id, :slot], unique: true
    add_index :relationships, [:target_id, :slot]
    add_index :relationships, [:target_id, :slot, :owner_model], unique: true, where: "exclusive", name: "index_relationships_exclusive"
    add_foreign_key :relationships, :entities, column: :entity_id, on_delete: :cascade
    add_foreign_key :relationships, :entities, column: :target_id, on_delete: :nullify

    # Marker (core) — EcsRails::Catalogue::Marker
    create_table :markers, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.timestamps
    end
    add_index :markers, [:entity_id, :slot], unique: true
    add_foreign_key :markers, :entities, column: :entity_id, on_delete: :cascade

    # Name (core) — EcsRails::Catalogue::Name
    create_table :names, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :given, default: nil
      t.string :family, default: nil
      t.string :full, default: nil
      t.timestamps
    end
    add_index :names, [:entity_id, :slot], unique: true
    add_foreign_key :names, :entities, column: :entity_id, on_delete: :cascade

    # Email (core) — EcsRails::Catalogue::Email
    create_table :emails, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :address, default: nil
      t.boolean :verified, default: false, null: false
      t.timestamps
    end
    add_index :emails, [:entity_id, :slot], unique: true
    add_foreign_key :emails, :entities, column: :entity_id, on_delete: :cascade

    # Password (core) — EcsRails::Catalogue::Password
    create_table :passwords, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :password_digest, default: nil
      t.timestamps
    end
    add_index :passwords, [:entity_id, :slot], unique: true
    add_foreign_key :passwords, :entities, column: :entity_id, on_delete: :cascade

    # Phone (core) — EcsRails::Catalogue::Phone
    create_table :phones, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :e164, default: nil, limit: 16
      t.string :extension, default: nil, limit: 8
      t.timestamps
    end
    add_index :phones, [:entity_id, :slot], unique: true
    add_foreign_key :phones, :entities, column: :entity_id, on_delete: :cascade

    # Address (core) — EcsRails::Catalogue::Address
    create_table :addresses, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :line1, default: nil
      t.string :line2, default: nil
      t.string :locality, default: nil
      t.string :region, default: nil
      t.string :postcode, default: nil
      t.string :country, default: nil, limit: 2
      t.timestamps
    end
    add_index :addresses, [:entity_id, :slot], unique: true
    add_foreign_key :addresses, :entities, column: :entity_id, on_delete: :cascade

    # Geolocation (core) — EcsRails::Catalogue::Geolocation
    create_table :geolocations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.decimal :lat, default: nil, precision: 10, scale: 7
      t.decimal :lng, default: nil, precision: 10, scale: 7
      t.datetime :geocoded_at, default: nil
      t.timestamps
    end
    add_index :geolocations, [:entity_id, :slot], unique: true
    add_foreign_key :geolocations, :entities, column: :entity_id, on_delete: :cascade

    # Link (core) — EcsRails::Catalogue::Link
    create_table :links, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :url, default: nil
      t.string :label, default: nil
      t.timestamps
    end
    add_index :links, [:entity_id, :slot], unique: true
    add_foreign_key :links, :entities, column: :entity_id, on_delete: :cascade

    # Text (core) — EcsRails::Catalogue::Text
    create_table :texts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.text :value, default: nil
      t.timestamps
    end
    add_index :texts, [:entity_id, :slot], unique: true
    add_foreign_key :texts, :entities, column: :entity_id, on_delete: :cascade

    # Identifier (core) — EcsRails::Catalogue::Identifier
    create_table :identifiers, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :value, default: nil
      t.timestamps
    end
    add_index :identifiers, [:entity_id, :slot], unique: true
    add_index :identifiers, [:slot, :value], unique: true
    add_foreign_key :identifiers, :entities, column: :entity_id, on_delete: :cascade

    # Counter (core) — EcsRails::Catalogue::Counter
    create_table :counters, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.integer :count, default: 0, null: false
      t.timestamps
    end
    add_index :counters, [:entity_id, :slot], unique: true
    add_foreign_key :counters, :entities, column: :entity_id, on_delete: :cascade

    # Rating (core) — EcsRails::Catalogue::Rating
    create_table :ratings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.integer :stars, default: nil
      t.timestamps
    end
    add_index :ratings, [:entity_id, :slot], unique: true
    add_foreign_key :ratings, :entities, column: :entity_id, on_delete: :cascade

    # Timestamp (core) — EcsRails::Catalogue::Timestamp
    create_table :timestamps, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.datetime :at, default: nil
      t.timestamps
    end
    add_index :timestamps, [:entity_id, :slot], unique: true
    add_foreign_key :timestamps, :entities, column: :entity_id, on_delete: :cascade

    # CalendarDate (core) — EcsRails::Catalogue::CalendarDate
    create_table :calendar_dates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.date :date, default: nil
      t.timestamps
    end
    add_index :calendar_dates, [:entity_id, :slot], unique: true
    add_foreign_key :calendar_dates, :entities, column: :entity_id, on_delete: :cascade

    # Period (core) — EcsRails::Catalogue::Period
    create_table :periods, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.datetime :starts_at, default: nil
      t.datetime :ends_at, default: nil
      t.string :time_zone, default: nil
      t.boolean :all_day, default: false, null: false
      t.timestamps
    end
    add_index :periods, [:entity_id, :slot], unique: true
    add_foreign_key :periods, :entities, column: :entity_id, on_delete: :cascade

    # Position (core) — EcsRails::Catalogue::Position
    create_table :positions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.integer :position, default: 0, null: false
      t.timestamps
    end
    add_index :positions, [:entity_id, :slot], unique: true
    add_index :positions, [:slot, :position]
    add_foreign_key :positions, :entities, column: :entity_id, on_delete: :cascade

    # State (core) — EcsRails::Catalogue::State
    create_table :states, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :status, default: nil
      t.jsonb :transitions, default: [], null: false
      t.timestamps
    end
    add_index :states, [:entity_id, :slot], unique: true
    add_foreign_key :states, :entities, column: :entity_id, on_delete: :cascade

    # Tags (core) — EcsRails::Catalogue::Tags
    create_table :tags, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :names, array: true, default: [], null: false
      t.timestamps
    end
    add_index :tags, [:entity_id, :slot], unique: true
    add_index :tags, :names, using: :gin
    add_foreign_key :tags, :entities, column: :entity_id, on_delete: :cascade

    # SearchVector (core) — EcsRails::Catalogue::SearchVector
    create_table :search_vectors, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.tsvector :document, default: nil
      t.timestamps
    end
    add_index :search_vectors, [:entity_id, :slot], unique: true
    add_index :search_vectors, :document, using: :gin
    add_foreign_key :search_vectors, :entities, column: :entity_id, on_delete: :cascade

    # Discard (core) — EcsRails::Catalogue::Discard
    create_table :discards, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.datetime :discarded_at, default: nil
      t.timestamps
    end
    add_index :discards, [:entity_id, :slot], unique: true
    add_foreign_key :discards, :entities, column: :entity_id, on_delete: :cascade

    # Image (core) — EcsRails::Catalogue::Image
    create_table :images, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :url, default: nil
      t.string :alt, default: nil
      t.timestamps
    end
    add_index :images, [:entity_id, :slot], unique: true
    add_foreign_key :images, :entities, column: :entity_id, on_delete: :cascade

    # Role (core) — EcsRails::Catalogue::Role
    create_table :roles, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :name, default: nil
      t.timestamps
    end
    add_index :roles, [:entity_id, :slot], unique: true
    add_foreign_key :roles, :entities, column: :entity_id, on_delete: :cascade

    # Token (core) — EcsRails::Catalogue::Token
    create_table :tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.string :slot, null: false, default: ""
      t.string :digest, default: nil
      t.datetime :expires_at, default: nil
      t.timestamps
    end
    add_index :tokens, [:entity_id, :slot], unique: true
    add_index :tokens, :digest
    add_foreign_key :tokens, :entities, column: :entity_id, on_delete: :cascade
  end
end
