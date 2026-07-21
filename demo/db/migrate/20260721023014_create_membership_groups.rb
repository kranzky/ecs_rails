# frozen_string_literal: true

# Creates the membership_groups relationship backing table
# (RFC-0012 / ADR-0013). This is what `relates_to :group,
# Group` reads; there is no relationship component file — the
# DSL defines the backing component dynamically.
#
# The owner side (entity_id) and the target side (group_id) are
# deliberately asymmetric:
#   - entity_id: not-null, UNIQUE (ADR-0005: at most one per owner), ON DELETE
#     CASCADE — destroying the owner destroys the link.
#   - group_id: nullable, ON DELETE NULLIFY — destroying the
#     TARGET nullifies the link, it does NOT cascade to the owner.
class CreateMembershipGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :membership_groups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.uuid :group_id, default: nil
      t.timestamps
    end

    # ADR-0005: at most one relationship row per owner entity.
    add_index :membership_groups, :entity_id, unique: true

    # Destroying the owner destroys the link, at the database level.
    add_foreign_key :membership_groups, :entities, column: :entity_id, on_delete: :cascade

    # Destroying the TARGET nullifies the link — it does not cascade to the owner.
    add_index :membership_groups, :group_id
    add_foreign_key :membership_groups, :entities, column: :group_id, on_delete: :nullify
  end
end
