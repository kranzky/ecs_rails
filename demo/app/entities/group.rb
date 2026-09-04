# frozen_string_literal: true

class Group < ApplicationEntity
  component Name                          # group.name_first
  component Description                   # group.description_text — what the group is
  # The same component again, in a labelled slot (RFC-0014 / ADR-0015): one
  # `descriptions` table, two rows per group at most, told apart by `slot`.
  # Reader `rules_description`, delegation `rules_description_text`.
  component Description, prefix: :rules   # group.rules_description_text — the house rules
end
