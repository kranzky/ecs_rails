# frozen_string_literal: true

# Test doubles for a host application's models.
#
# This file grows as the RFCs land. Keep it minimal: it should only contain
# what the specs actually exercise, and it should read the way a real host app
# would read. If something here looks awkward, that is a signal about the gem's
# API, not about the test setup — note it and raise it.

class ApplicationEntity < EcsRails::Entity
  self.abstract_class = true
end

class ApplicationComponent < EcsRails::Component
  self.abstract_class = true
end

# --- components --------------------------------------------------------------

class Email < ApplicationComponent
  validates :address, presence: true, format: { with: /@/, message: "is invalid" }

  def send_welcome_email
    :sent
  end

  # Pins ADR-0001: self is the component, never the entity.
  def who_am_i
    self
  end
end

class Name < ApplicationComponent
  def full_name
    [first, last].compact.join(" ")
  end
end

# Deliberately also defines #title, to exercise the delegation conflict in
# ADR-0004 / RFC-0005 against Name.
class Group < ApplicationComponent
end

class Avatar < ApplicationComponent
end

# --- entities ----------------------------------------------------------------

# The first real use of the gem's API (RFC-0004). Read it as a host app would
# write it: an entity is a list of the components it is composed from, and
# nothing else.
#
# `except: [:title]` is the escape hatch from ADR-0004: Name and Group both
# expose #title, and delegating both would be a DelegationConflict. RFC-0005
# raises it; RFC-0004 only records the option, so this line is inert today and
# load-bearing the moment delegation lands.
class User < ApplicationEntity
  component Name
  component Email
  component Group, except: [:title]
end

# A second entity sharing a component type with the first. "Shared components"
# means shared component *types*, never shared rows (ADR-0005).
class Post < ApplicationEntity
  component Name
  component Avatar
end
