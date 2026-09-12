# frozen_string_literal: true

# A customer's current, unplaced selection. One per user — `unique: true` on
# the relationship is a partial unique index in the database, and it is what
# lets User declare `has_one :basket, via: :customer`. The items are a real
# has_many over the shared relationships table (RFC-0015); the child is named
# because `items` does not infer `BasketItem`.
class Basket < ApplicationEntity
  component Counter, prefix: :revision

  relates_to :customer, User, unique: true
  has_many :items, "BasketItem", via: :basket, dependent: :destroy   # basket.items

  # Lock the always-present customer row while creating the singleton basket.
  def self.for(user)
    user.with_lock { user.basket || user.create_basket! }
  end

  # Checkout and all item writes share this lock. Reading inside it also drops
  # any collection cached before a competing request committed.
  def mutate!
    with_lock do
      items.reset
      result = yield
      self.revision += 1
      save!
      result
    end
  end

  def add_product!(product, quantity:)
    mutate! do
      if (item = items.with_related(:product, product).first)
        item.update!(quantity: item.quantity + quantity)
        item
      else
        BasketItem.create!(basket: self, product: product, quantity: quantity)
      end
    end
  end

  def update_item!(id, quantity:)
    mutate! { items.find(id).update!(quantity: quantity) }
  end

  def remove_item!(id)
    mutate! { items.find(id).destroy! }
  end

  def total
    items.includes_components(Counter).preload(product_relationship: { target: :price_money })
         .map(&:line_total).reduce(Money.new(amount_cents: 0, currency: "USD"), :+)
  end

  # Empties the basket. `dependent: :destroy` only removes link rows; the items
  # are entities of their own, so they are destroyed as such.
  def clear!
    mutate! do
      items.each(&:destroy!)
      items.reset
    end
  end
end
