# frozen_string_literal: true

module Demo
  # The marketplace's first transactional System: a PORO that turns a Basket
  # into a paid Order with an Invoice, in one database transaction. It touches
  # nine entity types' components and no entity subclass beyond the ones it
  # creates. Everything that could change later is COPIED onto the order —
  # addresses, unit prices, titles — never linked (design §4).
  #
  # What the gem does not give it, on purpose: scheduling, idempotency, retry.
  # A double-submit relies on the browser and the basket being empty afterwards.
  class Checkout
    class Error < StandardError; end

    ADDRESS_FIELDS = %w[line1 line2 locality region postcode country].freeze

    def self.call(**) = new(**).call

    def initialize(basket:, card_number:, shipping: {}, billing: {})
      @basket = basket
      @card_number = card_number
      @shipping = shipping
      @billing = billing
    end

    def call
      items = @basket.items.includes_components(Counter).to_a
      raise Error, "the basket is empty" if items.empty?

      ApplicationEntity.transaction do
        order = Order.new(customer: @basket.customer, order_number: Numbering.next("order_number", "ORD"))
        order.shipping_address.assign_attributes(@shipping.slice(*ADDRESS_FIELDS))
        order.billing_address.assign_attributes(@billing.slice(*ADDRESS_FIELDS))
        order.save!

        total = items.reduce(Money.new(amount_cents: 0, currency: "USD")) do |sum, item|
          sum + add_line(order, item)                          # Money#+ guards the currency
        end
        order.total_money.assign_attributes(amount_cents: total.amount_cents, currency: total.currency)
        order.fulfilment_state.status = "pending"
        order.save!

        PaymentGateway.charge!(order.total_money, card_number: @card_number)   # raises → rollback
        order.fulfilment_state.transition!(:paid, event: "pay")

        Invoice.issue_for(order)
        @basket.clear!
        order
      end
    rescue PaymentGateway::Declined => e
      raise Error, "Payment failed: #{e.message}"
    rescue Money::CurrencyMismatch => e
      raise Error, "The basket mixes currencies: #{e.message}"
    end

    private

    # One order line: the product's price and title copied, stock taken.
    def add_line(order, item)
      product = item.product
      raise Error, "#{product.title} is no longer listed" unless product.listed?
      raise Error, "only #{product.stock} of #{product.title} in stock" if product.stock < item.quantity

      line = OrderItem.new(order: order, product: product, title: product.title, quantity: item.quantity)
      line.unit_price_money.assign_attributes(product.price_money.attributes.slice("amount_cents", "currency"))
      line.save!

      product.stock -= item.quantity
      product.save!
      line.line_total
    end
  end
end
