# frozen_string_literal: true

# Basket × Product with a quantity: the unbounded "many" is a join entity
# (ADR-0005), never a plural component. Its price is the product's LIVE price —
# a basket line has no price of its own until checkout snapshots one.
class BasketItem < ApplicationEntity
  relates_to :basket,  Basket
  relates_to :product, Product
  component Counter, prefix: :quantity   # item.quantity

  def line_total
    product.price_money * quantity
  end
end
