# frozen_string_literal: true

# A join entity (ADR-0005): many-to-many is modelled as its own entity composed
# from relationship components, since a component appears at most once per entity.
class Membership < ApplicationEntity
  component MemberUser
  component MemberGroup
  component Role
end
