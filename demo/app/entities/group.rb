# frozen_string_literal: true

# A group is three Texts under three slots — one `texts` table, three rows at
# most — and nothing else. An organisation's name is Text under slot "name"
# (ADR-0018 §5); a person's is the Name component.
class Group < ApplicationEntity
  component Text, prefix: :name          # group.name_text
  component Text, prefix: :description   # group.description_text
  component Text, prefix: :rules         # group.rules_text — the house rules
end
