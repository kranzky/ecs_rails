# frozen_string_literal: true

# The base class for every entity in this application.
#
# An entity is an immutable identity row: a UUID, a `model` discriminator and
# its creation time. All mutable domain state lives in components.
#
#   class User < ApplicationEntity
#     component Email
#   end
#
# See docs/architecture.md §1.
class ApplicationEntity < EcsRails::Entity
  self.abstract_class = true
end
