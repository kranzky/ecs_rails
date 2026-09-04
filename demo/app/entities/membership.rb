# frozen_string_literal: true

# A join entity (ADR-0005): many-to-many modelled as an entity carrying two
# relationships — two rows in the shared `relationships` table — plus a Role,
# because the role belongs to the link, not to the person or the group.
class Membership < ApplicationEntity
  relates_to :user, User
  relates_to :group, Group
  component Role                         # membership.role_name
end
