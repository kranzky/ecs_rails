# frozen_string_literal: true

# A person. Every component here is from the catalogue (ADR-0018); the table
# for each already exists, so this class needed no migration.
class User < ApplicationEntity
  component Name                     # user.name_given, user.name_family, user.name.initials
  component Email                    # user.email_address, user.email_verified
  component Image, prefix: :avatar   # user.avatar_image.url
  component Text,  prefix: :bio      # user.bio (the String), user.bio_text (the Text)
  # Markers (RFC-0016): a user IS a moderator exactly when the (user, "moderator")
  # row exists in `markers`. user.add(:moderator), user.moderator?, user.remove.
  # Two Address slots and two Phone slots: fixed, named roles — the plural
  # components case (RFC-0014). Same tables as the companies' addresses and
  # phones; the slot tells them apart.
  component Address, prefix: :shipping    # user.shipping_address
  component Address, prefix: :billing     # user.billing_address
  component Phone,   prefix: :mobile      # user.mobile_phone
  component Phone,   prefix: :work        # user.work_phone
  marker :moderator
  marker :administrator
  # The parent side of three relationships (RFC-0015).
  has_many :posts,       via: :author   # user.posts
  has_many :comments,    via: :author   # user.comments
  has_many :memberships, via: :user     # user.memberships
  has_many :employments, via: :user     # user.employments — the seller side, same user
  has_many :reviews,     via: :author   # user.reviews
  has_one  :basket,      via: :customer # user.basket — the child's unique: true makes this a has_one
  has_many :orders,      via: :customer # user.orders
end
