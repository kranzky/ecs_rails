# frozen_string_literal: true

# The one component every marker is a row of (ADR-0018 §4). A marker has no
# state: an entity IS a moderator exactly when its row exists. Every marker in
# this application lives in the `markers` table; the slot is the marker name.
#
#   class User < ApplicationEntity
#     marker :moderator        # user.add(:moderator), user.moderator?, user.remove(:moderator)
#   end
#
# A catalogue component (ADR-0018): the application owns the constant. If your
# domain already has a `Marker`, rename this class and set
# `config.marker_class_name` in config/initializers/ecs_rails.rb.
class Marker < ApplicationComponent
  include EcsRails::Catalogue::Marker
end
