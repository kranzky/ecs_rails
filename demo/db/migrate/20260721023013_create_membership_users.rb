# frozen_string_literal: true

# Creates the membership_users relationship backing table
# (RFC-0012 / ADR-0013). This is what `relates_to :user,
# User` reads; there is no relationship component file — the
# DSL defines the backing component dynamically.
#
# The owner side (entity_id) and the target side (user_id) are
# deliberately asymmetric:
#   - entity_id: not-null, UNIQUE (ADR-0005: at most one per owner), ON DELETE
#     CASCADE — destroying the owner destroys the link.
#   - user_id: nullable, ON DELETE NULLIFY — destroying the
#     TARGET nullifies the link, it does NOT cascade to the owner.
class CreateMembershipUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :membership_users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.uuid :user_id, default: nil
      t.timestamps
    end

    # ADR-0005: at most one relationship row per owner entity.
    add_index :membership_users, :entity_id, unique: true

    # Destroying the owner destroys the link, at the database level.
    add_foreign_key :membership_users, :entities, column: :entity_id, on_delete: :cascade

    # Destroying the TARGET nullifies the link — it does not cascade to the owner.
    add_index :membership_users, :user_id
    add_foreign_key :membership_users, :entities, column: :user_id, on_delete: :nullify
  end
end
