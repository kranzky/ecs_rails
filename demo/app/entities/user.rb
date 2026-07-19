# frozen_string_literal: true

class User < ApplicationEntity
  component Name
  component Email
  component Avatar
  component Bio
  # Marker components (ADR-0009): a user IS a moderator/administrator exactly
  # when the row exists. Set presence with user.add(Moderator) / user.remove,
  # ask with user.moderator?. The lazy save cascade never persists these on its
  # own — they have no state to dirty — so presence must be explicit.
  component Moderator
  component Administrator
end
