# frozen_string_literal: true

module EcsRails
  module Catalogue
    # An identifier: sku, order_number, invoice_number, slug, an external id
    # (`stripe_customer`) — one slot each, **unique per slot** at the database.
    module Identifier
      extend Definition

      table "identifiers"
      schema do |t|
        t.string :value, default: nil
        t.index %i[slot value], unique: true
      end

      # @return [String] the value, or ""
      def to_s
        value.to_s
      end
    end
  end
end
