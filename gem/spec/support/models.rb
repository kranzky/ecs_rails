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

# A method mixed in from a module rather than defined in the class body. Pins
# the fiddly part of RFC-0005: the delegated set is "methods the component
# itself declares", which must include methods it gains from included modules —
# Name.instance_methods(false) would miss #initials, so the computation cannot
# be that. See EcsRails::DSL#delegable_methods.
module Nameable
  def initials
    [first, last].compact.map { |part| part[0] }.join
  end
end

class Name < ApplicationComponent
  include Nameable

  def full_name
    [first, last].compact.join(" ")
  end

  # A distinguishable return value so the conflict-resolution test can prove
  # *which* component's #title survived `except:` (RFC-0005). Overrides the
  # column reader; the writer #title= still comes from the column.
  def title
    "from Name"
  end

  # Takes positional args, a keyword arg and a block, so delegation can be shown
  # to forward all three (RFC-0005: "forwards *args, **kwargs, and &block").
  def combine(*parts, separator: "-", &block)
    joined = parts.join(separator)
    block ? block.call(joined) : joined
  end
end

# Shares a #title accessor with Name (both have a `title` column, see
# spec/support/schema.rb), to exercise the delegation conflict in
# ADR-0004 / RFC-0005. User resolves it with `component Group, except: [:title]`.
class Group < ApplicationComponent
end

class Avatar < ApplicationComponent
end

# A marker component (ADR-0009 / RFC-0009): zero state, presence is the whole
# meaning. Has no attributes at all, so it is never `ecs_dirty?` and the lazy
# save cascade would never write it — `user.moderator; user.save!` persists
# nothing. Presence has to be set explicitly: `user.add(Moderator)`. This is the
# exact shape of the demo's Moderator/Administrator.
class Moderator < ApplicationComponent
end

# A concrete, stateful component deliberately declared on *no* entity here, so
# `user.add(PublishState)` / `has?` raise EcsRails::InvalidComponent — the
# "component the entity does not declare" path in RFC-0009.
class PublishState < ApplicationComponent
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
  # A marker (RFC-0009). Presence is set with `user.add(Moderator)`, asked with
  # `user.moderator?`, and cleared with `user.remove(Moderator)`.
  component Moderator
end

# A second entity sharing a component type with the first. "Shared components"
# means shared component *types*, never shared rows (ADR-0005).
class Post < ApplicationEntity
  component Name
  component Avatar
end

# A relationship component (ADR-0006) whose association name collides with its
# own reader: reader for `component Sponsor` is `sponsor`, and `belongs_to
# :sponsor` also defines `sponsor`. Declaring it used to overwrite the reader
# and recurse infinitely (SystemStackError); it now raises a reader collision at
# declaration time. Surfaced building the demo. Not declared on any entity here
# — the specs declare it on stub_const entities to assert the raise.
class Sponsor < ApplicationComponent
  belongs_to :sponsor, class_name: "User", foreign_key: :sponsor_id, optional: true
end
