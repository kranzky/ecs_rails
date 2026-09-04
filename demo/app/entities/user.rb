# frozen_string_literal: true

class User < ApplicationEntity
  component Name
  component Email
  component Avatar
  component Bio
  # Markers (ADR-0009 / RFC-0016): a user IS a moderator/administrator exactly
  # when the row exists — one `markers` table, slot = the marker name. Set
  # presence with user.add(:moderator) / user.remove(:moderator), ask with
  # user.moderator?. The lazy save cascade never persists these on its own —
  # they have no state to dirty — so presence must be explicit.
  marker :moderator
  marker :administrator
end
