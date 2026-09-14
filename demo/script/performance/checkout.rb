# frozen_string_literal: true

module PerformanceComparison
  # Ordinary Rails counterpart to Demo::Checkout. It has the same observable
  # outcome/rollback contract; normalized rows replace components and links.
  class PlainCheckout
    MoneyValue = Struct.new(:amount_cents, :currency) do
      def zero? = amount_cents.zero?
    end

    def self.call(basket:, card_number:, shipping: {}, billing: {}, revision: nil)
      basket.with_lock do
        submitted = revision.nil? ? basket.revision : revision.to_s
        raise Demo::Checkout::Error, "invalid revision" unless submitted.to_s.match?(/\A\d{1,10}\z/)
        submitted = submitted.to_i
        request = "#{basket.id}:#{submitted}"
        completed = Plain::Order.find_by(customer_id: basket.customer_id, checkout_request: request)
        next completed if completed
        raise Demo::Checkout::Error, "stale revision" unless submitted == basket.revision

        items = basket.items.reset.to_a
        raise Demo::Checkout::Error, "empty basket" if items.empty?
        products = Plain::Product.where(id: items.map(&:product_id).uniq.sort).order(:id).lock.index_by(&:id)
        order = Plain::Order.create!(customer_id: basket.customer_id, checkout_request: request,
                                     number: next_number(Plain::Order, "ORD", 1),
                                     **address_columns("shipping", shipping), **address_columns("billing", billing))
        total = 0
        items.each do |item|
          product = products.fetch(item.product_id)
          raise Demo::Checkout::Error, "quantity must be positive" unless item.quantity.positive?
          raise Demo::Checkout::Error, "not listed" unless product.status == "listed"
          raise Demo::Checkout::Error, "out of stock" if product.stock < item.quantity
          raise ::Money::CurrencyMismatch, "mixed currencies" unless product.currency == "USD"

          Plain::OrderItem.create!(order: order, product: product, title: product.title,
                                  quantity: item.quantity, amount_cents: product.amount_cents, currency: product.currency)
          product.update!(stock: product.stock - item.quantity)
          total += product.amount_cents * item.quantity
        end
        order.update!(total_cents: total, currency: "USD", status: "pending")
        Demo::PaymentGateway.charge!(MoneyValue.new(total, "USD"), card_number: card_number)
        order.update!(status: "paid", transitions: [{ "at" => Time.current.iso8601, "from" => "pending", "to" => "paid", "event" => "pay" }])
        Plain::Invoice.create!(order: order, number: next_number(Plain::Invoice, "INV", 2),
                              total_cents: total, currency: "USD", issued_at: Time.current,
                              **address_columns("billing", billing))
        items.each(&:destroy!)
        basket.update!(revision: basket.revision + 1)
        order
      end
    rescue Demo::PaymentGateway::Declined, ::Money::CurrencyMismatch => error
      raise Demo::Checkout::Error, error.message
    end

    def self.address_columns(prefix, address)
      address.stringify_keys.slice(*Demo::Checkout::ADDRESS_FIELDS).transform_keys { |field| "#{prefix}_#{field}" }
    end

    def self.next_number(model, prefix, key)
      model.connection.execute("SELECT pg_advisory_xact_lock(33025, #{key})")
      last = model.where("number ~ ?", "^#{prefix}-[0-9]+$").maximum(Arel.sql("split_part(number, '-', 2)::bigint")) || 0
      format("%s-%06d", prefix, last + 1)
    end
  end
end
