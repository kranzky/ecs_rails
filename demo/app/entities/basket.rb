# frozen_string_literal: true

# A customer's current, unplaced selection. One per user — `unique: true` on
# the relationship is a partial unique index in the database, and it is what
# lets User declare `has_one :basket, via: :customer`. The items are a real
# has_many over the shared relationships table (RFC-0015); the child is named
# because `items` does not infer `BasketItem`.
class Basket < ApplicationEntity
  relates_to :customer, User, unique: true
  has_many :items, "BasketItem", via: :basket, dependent: :destroy   # basket.items

  def total
    items.includes_components(Counter).preload(product_relationship: { target: :price_money })
         .map(&:line_total).reduce(Money.new(amount_cents: 0, currency: "USD"), :+)
  end

  # Empties the basket. `dependent: :destroy` only removes link rows; the items
  # are entities of their own, so they are destroyed as such.
  def clear!
    items.each(&:destroy)
    items.reset
  end
end
