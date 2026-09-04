# frozen_string_literal: true

# One line of an Order. The unit price and title are SNAPSHOTS — copies of the
# product's Money and Text at checkout, never a link to the live components —
# because a later price edit must not rewrite history (design §4).
class OrderItem < ApplicationEntity
  relates_to :order,   Order
  relates_to :product, Product
  component Text,    prefix: :title        # item.title — as sold
  component Counter, prefix: :quantity     # item.quantity
  component Money,   prefix: :unit_price   # item.unit_price_money — as sold

  def line_total
    unit_price_money * quantity
  end
end
