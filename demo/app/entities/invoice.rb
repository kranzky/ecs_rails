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

  # The caller holds one transaction through number allocation and insertion.
  def self.next_number = Demo::Numbering.next("invoice_number", "INV")

  def self.issue_for(order)
    transaction do
      invoice = new(order: order, invoice_number: next_number)
      invoice.total_money.assign_attributes(order.total_money.attributes.slice("amount_cents", "currency"))
      invoice.billing_address.assign_attributes(order.billing_address.attributes.slice(*Demo::Checkout::ADDRESS_FIELDS))
      invoice.issued_at = Time.current
      invoice.save!
      invoice
    end
  end
end
