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
# ADR-0004 / RFC-0005. Under ADR-0016 the two no longer clash on User — they
# delegate as `name_title` and `group_title` — so the conflict specs declare
# both with `prefix: false` to force the bare names back into one namespace.
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

# A naturally multi-role component (RFC-0014 / ADR-0015): a user has a postal
# address and a business address, a supplier a remit-to address. One class, one
# table, several slots. Not declared on the shared fixtures — spec/slots_spec.rb
# declares it on throwaway entities so the preloading query counts here stay
# what they are.
#
# `slot_option :country` is RFC-0014's slot configuration: the declaring entity
# may pass `country: "NZ"` on the `component` line, and the instance reads it
# back as `#country`. Unknown options raise at declaration time.
class Address < ApplicationComponent
  slot_option :country, default: "AU"

  validates :postcode, format: { with: /\A\d{4}\z/, allow_nil: true }

  def one_line
    [line1, region, postcode, country].compact.join(", ")
  end
end

# --- entities ----------------------------------------------------------------

# The first real use of the gem's API (RFC-0004). Read it as a host app would
# write it: an entity is a list of the components it is composed from, and
# nothing else.
#
# Name and Group both expose #title. Before ADR-0016 that was a
# DelegationConflict, resolved here with `component Group, except: [:title]`.
# Delegation is reader-prefixed now — `user.name_title`, `user.group_title` —
# so the two coexist with no option at all. That is the ADR's whole payoff, and
# this fixture reads the way a host app would write it after it.
class User < ApplicationEntity
  component Name
  component Email
  component Group
  # A marker (RFC-0009). Presence is set with `user.add(Moderator)`, asked with
  # `user.moderator?`, and cleared with `user.remove(Moderator)`.
  component Moderator
end

# A second entity sharing a component type with the first. "Shared components"
# means shared component *types*, never shared rows (ADR-0005).
#
# `relates_to :author, User` (RFC-0012 / ADR-0013) is the cross-entity link. It
# writes no relationship component file: it dynamically defines the backing
# component `Post::AuthorRelationship` (table `post_authors`) and declares it, so
# `post.author` / `post.author=` reach the User via delegation and
# `post.author_relationship` is the backing reader. This is exactly the shape of
# the demo's old hand-written `Authorship` component.
class Post < ApplicationEntity
  component Name
  component Avatar
  relates_to :author, User
end

# A SECOND entity relating `:author` to the same target as Post (RFC-0013). Its
# owner-scoped backing table is `comment_authors`, distinct from Post's
# `post_authors`, so `Post.with_related(:author, ada)` returning only posts is a
# real assertion that relationship-name sugar does not leak across entity types
# (the ADR-0011 scoping it inherits from `with_component`).
class Comment < ApplicationEntity
  relates_to :author, User
end

# A target entity for a *second* relationship on a join entity. The gem's `Group`
# fixture is a component, not an entity, so it cannot stand in for a relationship
# target — hence a dedicated entity here. Entities need no table of their own
# (they share `entities`, ADR-0002), so this costs one constant.
class Team < ApplicationEntity
end

# A join entity (ADR-0005): many-to-many is modelled as an entity carrying two
# `relates_to` declarations, which is precisely what `relates_to` makes cheap.
# Backing tables `membership_users` and `membership_teams`.
class Membership < ApplicationEntity
  relates_to :user, User
  relates_to :team, Team
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
