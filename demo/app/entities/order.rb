# frozen_string_literal: true

# A placed, paid basket — frozen. The addresses are COPIES of the customer's
# slots at checkout (two Address slots, `shipping` and `billing`, the RFC-0014
# showcase), the total a Money the Checkout system computed, and the lifecycle
# a State whose vocabulary is declared here, on the slot, not on the component.
class Order < ApplicationEntity
  STATES = %w[pending paid shipped delivered cancelled].freeze

  component Identifier, prefix: :order_number                       # order.order_number
  component Money,      prefix: :total                              # order.total_money
  component State,      prefix: :fulfilment, states: STATES         # order.fulfilment_state
  component Address,    prefix: :shipping                           # order.shipping_address
  component Address,    prefix: :billing                            # order.billing_address
  relates_to :customer, User
  has_many :items, "OrderItem", via: :order, dependent: :destroy    # order.items
  has_one  :invoice, via: :order                                    # order.invoice

  def status = fulfilment_state.status || "pending"

  # The transitions the order page offers from each state.
  NEXT = { "paid" => %w[shipped cancelled], "shipped" => %w[delivered] }.freeze

  def next_states = NEXT.fetch(status, [])

  def transition!(to)
    raise ArgumentError, "#{status} → #{to} is not allowed" unless next_states.include?(to.to_s)

    fulfilment_state.transition!(to, event: to.to_s)
  end
end
