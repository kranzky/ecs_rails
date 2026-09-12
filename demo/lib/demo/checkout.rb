# frozen_string_literal: true

module Demo
  # The marketplace's first transactional System: a PORO that turns a Basket
  # into a paid Order with an Invoice, in one database transaction. It touches
  # nine entity types' components and no entity subclass beyond the ones it
  # creates. Everything that could change later is COPIED onto the order —
  # addresses, unit prices, titles — never linked (design §4).
  #
  # Basket revisions identify submissions; completed repeats return the original
  # order. Locks and request records belong to this application (ECS-28).
  class Checkout
    class Error < StandardError; end

    ADDRESS_FIELDS = %w[line1 line2 locality region postcode country].freeze

    def self.call(**) = new(**).call

    def initialize(basket:, card_number:, shipping: {}, billing: {}, revision: nil)
      @basket = basket
      @revision = revision
      @card_number = card_number
      @shipping = shipping
      @billing = billing
    end

    def call
      @basket.with_lock do
        revision = submission_revision
        request = "#{@basket.id}:#{revision}"
        completed = @basket.customer.orders.with_component(Identifier, prefix: :checkout_request, value: request).first
        next completed if completed
        raise Error, "The basket changed; review it before checking out again." unless revision == @basket.revision

        items = @basket.items.reset.includes_components(Counter).to_a
        raise Error, "the basket is empty" if items.empty?
        stocks = lock_stock(items)

        order = Order.new(customer: @basket.customer, checkout_request: request,
                          order_number: Numbering.next("order_number", "ORD"))
        order.shipping_address.assign_attributes(@shipping.slice(*ADDRESS_FIELDS))
        order.billing_address.assign_attributes(@billing.slice(*ADDRESS_FIELDS))
        order.save!

        total = items.reduce(Money.new(amount_cents: 0, currency: "USD")) do |sum, item|
          sum + add_line(order, item, stocks)  # Money#+ guards the currency
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

    def submission_revision
      return @basket.revision if @revision.nil?

      value = @revision.to_s
      raise Error, "The checkout form is invalid; please open it again." unless value.match?(/\A\d{1,10}\z/)

      value.to_i
    end

    # Lock component rows, not entity identities. Absent stock stays virtual
    # zero; a positive order cannot consume it. All checkouts use this order.
    def lock_stock(items)
      ids = items.map(&:product_id).uniq.sort
      Counter.where(slot: "stock", entity_id: ids).order(:entity_id).lock.index_by(&:entity_id)
    end

    # One order line: the product's price and title copied, stock taken.
    def add_line(order, item, stocks)
      product = Product.find(item.product_id)
      stock = stocks[product.id]
      available = stock&.count || 0
      raise Error, "quantity must be positive" unless item.quantity.positive?
      raise Error, "#{product.title} is no longer listed" unless product.listed?
      raise Error, "only #{available} of #{product.title} in stock" if available < item.quantity

      line = OrderItem.new(order: order, product: product, title: product.title, quantity: item.quantity)
      line.unit_price_money.assign_attributes(product.price_money.attributes.slice("amount_cents", "currency"))
      line.save!

      stock.update!(count: available - item.quantity)
      line.line_total
    end
  end
end
