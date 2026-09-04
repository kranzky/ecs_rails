# frozen_string_literal: true

module EcsRails
  module Catalogue
    # An amount of money: integer minor units and an ISO 4217 currency code —
    # never a float. In the `commerce` set.
    #
    #   product.price_money.amount_cents = 1999
    #   product.price_money.to_s                    # => "USD 19.99"
    #   total = line.price_money + other.price_money  # same currency, or CurrencyMismatch
    module Money
      extend Definition

      # Raised by arithmetic across currencies.
      class CurrencyMismatch < EcsRails::Error; end

      table "monies"
      set :commerce
      schema do |t|
        t.integer :amount_cents, default: 0, null: false
        t.string  :currency,     default: "USD", null: false, limit: 3
      end

      included do
        validates :currency, format: { with: /\A[A-Z]{3}\z/ }
      end

      # @return [BigDecimal] the amount in major units
      def amount
        BigDecimal(amount_cents) / 100
      end

      # @param value [Numeric] major units
      # @return [Integer] the stored cents
      def amount=(value)
        self.amount_cents = (BigDecimal(value.to_s) * 100).round.to_i
      end

      # @return [Boolean]
      def zero?
        amount_cents.zero?
      end

      # A new, unsaved instance holding the sum; same currency required.
      #
      # @param other [Money]
      # @return [ActiveRecord::Base]
      # @raise [CurrencyMismatch]
      def +(other)
        ecs_same_currency!(other)
        self.class.new(amount_cents: amount_cents + other.amount_cents, currency: currency)
      end

      # A new, unsaved instance holding the difference; same currency required.
      #
      # @param other [Money]
      # @return [ActiveRecord::Base]
      # @raise [CurrencyMismatch]
      def -(other)
        ecs_same_currency!(other)
        self.class.new(amount_cents: amount_cents - other.amount_cents, currency: currency)
      end

      # A new, unsaved instance scaled by `factor`, rounded to a cent.
      #
      # @param factor [Numeric]
      # @return [ActiveRecord::Base]
      def *(factor)
        self.class.new(amount_cents: (amount_cents * factor).round, currency: currency)
      end

      # @return [String] e.g. "USD 19.99"
      def to_s
        format("%s %.2f", currency, amount)
      end

      private

      def ecs_same_currency!(other)
        return if other.currency == currency

        raise CurrencyMismatch, "cannot combine #{currency} with #{other.currency}"
      end
    end
  end
end
