# frozen_string_literal: true

# A join entity (ADR-0005): many-to-many modelled as an entity carrying two
# relationships, which relates_to makes cheap: two rows in the shared
# relationships table (ADR-0017), slots "user" and "group".
class Membership < ApplicationEntity
  relates_to :user, User
  relates_to :group, Group
  component Role
end
