# frozen_string_literal: true

module Demo
  # Sequential document numbers from an Identifier slot. Entities have UUID
  # primary keys, so there is no natural incrementing number; "max + 1" inside
  # the caller's transaction, with Identifier's unique (slot, value) index as
  # the backstop, is the demo's answer (design §5, item 8).
  module Numbering
    module_function

    def next(slot, prefix)
      last = Identifier.where(slot: slot).maximum(:value).to_s.delete("^0-9").to_i
      format("%s-%06d", prefix, last + 1)
    end
  end
end
