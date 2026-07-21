# frozen_string_literal: true

# Creates the comment_authors relationship backing table
# (RFC-0012 / ADR-0013). This is what `relates_to :author,
# User` reads; there is no relationship component file — the
# DSL defines the backing component dynamically.
#
# The owner side (entity_id) and the target side (author_id) are
# deliberately asymmetric:
#   - entity_id: not-null, UNIQUE (ADR-0005: at most one per owner), ON DELETE
#     CASCADE — destroying the owner destroys the link.
#   - author_id: nullable, ON DELETE NULLIFY — destroying the
#     TARGET nullifies the link, it does NOT cascade to the owner.
class CreateCommentAuthors < ActiveRecord::Migration[8.1]
  def change
    create_table :comment_authors, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :entity_id, null: false
      t.uuid :author_id, default: nil
      t.timestamps
    end

    # ADR-0005: at most one relationship row per owner entity.
    add_index :comment_authors, :entity_id, unique: true

    # Destroying the owner destroys the link, at the database level.
    add_foreign_key :comment_authors, :entities, column: :entity_id, on_delete: :cascade

    # Destroying the TARGET nullifies the link — it does not cascade to the owner.
    add_index :comment_authors, :author_id
    add_foreign_key :comment_authors, :entities, column: :author_id, on_delete: :nullify
  end
end
