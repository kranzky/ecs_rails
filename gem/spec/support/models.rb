# frozen_string_literal: true

# Test doubles for a host application's models.
#
# This file grows as the RFCs land. Keep it minimal: it should only contain
# what the specs actually exercise, and it should read the way a real host app
# would read. If something here looks awkward, that is a signal about the gem's
# API, not about the test setup — note it and raise it.

class ApplicationEntity < Rorecs::Entity
  self.abstract_class = true
end

class ApplicationComponent < Rorecs::Component
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

class User < ApplicationEntity
end

class Post < ApplicationEntity
end
