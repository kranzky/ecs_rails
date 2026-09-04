# frozen_string_literal: true

# The document issued for an Order, once. `unique: true` makes `order.invoice`
# a has_one. Number, total, issue time and billing address are all copies —
# an invoice does not change when the order does.
class Invoice < ApplicationEntity
  component Identifier, prefix: :invoice_number   # invoice.invoice_number
  component Money,      prefix: :total            # invoice.total_money
  component Timestamp,  prefix: :issued_at        # invoice.issued_at
  component Address,    prefix: :billing          # invoice.billing_address
  relates_to :order, Order, unique: true

  # Sequential numbers from an Identifier slot: entities have UUID keys, so
  # "max + 1" inside the checkout transaction is the counter (design §5.8).
  # A race would collide on Identifier's unique (slot, value) index and roll
  # the whole checkout back, which is the right outcome.
  def self.next_number = Demo::Numbering.next("invoice_number", "INV")

  def self.issue_for(order)
    invoice = new(order: order, invoice_number: next_number)
    invoice.total_money.assign_attributes(order.total_money.attributes.slice("amount_cents", "currency"))
    invoice.billing_address.assign_attributes(order.billing_address.attributes.slice(*Demo::Checkout::ADDRESS_FIELDS))
    invoice.issued_at = Time.current
    invoice.save!
    invoice
  end
end
