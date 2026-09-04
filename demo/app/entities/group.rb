# frozen_string_literal: true

# A group is three Texts under three slots — one `texts` table, three rows at
# most — and nothing else. An organisation's name is Text under slot "name"
# (ADR-0018 §5); a person's is the Name component.
class Group < ApplicationEntity
  component Text, prefix: :name          # group.name
  component Text, prefix: :description   # group.description
  component Text, prefix: :rules         # group.rules — the house rules
  has_many :memberships, via: :group, dependent: :destroy   # group.memberships
end
