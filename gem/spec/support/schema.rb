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

  # --- relationship backing tables (RFC-0012 / ADR-0013) ---------------------
  #
  # These are what `relates_to` generates. Each is a component table on the
  # owner side (entity_id: not-null, unique, ON DELETE CASCADE — a post has at
  # most one author, and destroying the post destroys the link), plus a target
  # column whose FK is ON DELETE **NULLIFY**: destroying the target entity (the
  # User) nullifies the link, it does not cascade to the owner (the Post). That
  # nullify-not-cascade asymmetry is the load-bearing behaviour ADR-0013
  # specifies, and it is asserted against the real database in
  # spec/relationships_spec.rb.
  #
  # `post_authors` backs `Post.relates_to :author, User`.
  create_table :post_authors, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
    t.uuid :author_id, default: nil
    t.timestamps
  end

  # `membership_users` / `membership_teams` back the join-entity `Membership`,
  # which carries two relationships — the many-to-many pattern (ADR-0005).
  create_table :membership_users, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
    t.uuid :user_id,   default: nil
    t.timestamps
  end

  create_table :membership_teams, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
    t.uuid :team_id,   default: nil
    t.timestamps
  end

  # Backs the reload-safety scenario in spec/relationships_spec.rb, which
  # declares `relates_to :author, User` on a throwaway `Reloadable` entity (whose
  # owner-scoped table name is therefore `reloadable_authors`) and reads through
  # it after a simulated class reload.
  create_table :reloadable_authors, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid :entity_id, null: false
    t.uuid :author_id, default: nil
    t.timestamps
  end

  {
    post_authors: :author_id,
    membership_users: :user_id,
    membership_teams: :team_id,
    reloadable_authors: :author_id
  }.each do |table, target|
    add_index table, :entity_id, unique: true
    add_foreign_key table, :entities, column: :entity_id, on_delete: :cascade
    add_index table, target
    add_foreign_key table, :entities, column: target, on_delete: :nullify
  end
end
