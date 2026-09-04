# frozen_string_literal: true

module EcsRails
  module Catalogue
    # An ordering within a list — kanban columns, checklist items. One slot per
    # list an entity can be ordered in.
    module Position
      extend Definition

      table "positions"
      primary_attribute :position
      schema do |t|
        t.integer :position, default: 0, null: false
        t.index %i[slot position]
      end
    end
  end
end
