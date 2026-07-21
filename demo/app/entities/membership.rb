# frozen_string_literal: true

# A join entity (ADR-0005): many-to-many modelled as an entity carrying two
# relationships, which relates_to makes cheap. Backing tables membership_users
# and membership_groups.
class Membership < ApplicationEntity
  relates_to :user, User
  relates_to :group, Group
  component Role
end
