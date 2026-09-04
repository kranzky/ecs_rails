# frozen_string_literal: true

# A seller: the storefront a Product belongs to. Composed from the catalogue
# only — no migration was written for it (ADR-0018). The registered Address sits
# in the default slot so ECS-8's Geolocation can pair with it by slot.
class Company < ApplicationEntity
  component Text,  prefix: :name          # company.name
  component Text,  prefix: :description   # company.description
  component Image, prefix: :logo          # company.logo_image.url
  component Email                         # company.email_address
  component Phone                         # company.phone.to_s
  component Address                       # company.address.lines

  has_many :products,    via: :seller                        # company.products
  has_many :employments, via: :company, dependent: :destroy  # company.employments

  # Everyone who may act for this company, with their role — the Employment
  # join entity is the seller-side twin of the forum's Membership.
  def staff
    employments.includes_components(Role).preload(user_relationship: { target: :name })
  end
end
