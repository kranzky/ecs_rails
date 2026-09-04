# frozen_string_literal: true

module EcsRails
  module Catalogue
    # The one component every marker is a row of (ADR-0018 §4).
    #
    # A marker carries no state: an entity *is* a moderator exactly when the row
    # exists (ADR-0009). Under ADR-0018 all markers in an application share one
    # `markers` table — `(id, entity_id, slot, timestamps)`, `UNIQUE (entity_id,
    # slot)` — and the slot is the marker name. Declaring a marker is pure Ruby:
    #
    #   class User < ApplicationEntity
    #     marker :moderator          # slot "moderator" on the markers table
    #   end
    #
    #   user.add(:moderator)         # a row
    #   user.moderator?              # => true
    #   user.remove(:moderator)
    #
    # The host application owns the constant and includes this concern, exactly
    # as with {Relationship}:
    #
    #   class Marker < ApplicationComponent
    #     include EcsRails::Catalogue::Marker
    #   end
    #
    # There is nothing else to it. Presence is {EcsRails::Presence::Entity}'s;
    # the `marker` declaration ({EcsRails::Markers#marker}) is sugar over
    # `component Marker, prefix: :moderator, delegate: false` that restores the
    # bare `moderator?` predicate prefixing would otherwise take away.
    module Marker
      extend ActiveSupport::Concern

      included do
        self.table_name = "markers"
      end
    end
  end
end
