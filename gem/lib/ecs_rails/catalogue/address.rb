# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A postal address (schema.org `PostalAddress`), multi-role by nature:
    # `component Address, prefix: :shipping`, `prefix: :billing`.
    #
    # Named `Address`, not `PostalAddress`: ADR-0016 freed the short name
    # (`Email#address` delegates as `email_address`), and the slot reader rule
    # (`#{prefix}_#{singular}`) needs it to read `billing_address`.
    module Address
      extend Definition

      table "addresses"
      schema do |t|
        t.string :line1,    default: nil
        t.string :line2,    default: nil
        t.string :locality, default: nil
        t.string :region,   default: nil
        t.string :postcode, default: nil
        t.string :country,  default: nil, limit: 2
      end

      included do
        validates :country, format: { with: /\A[A-Z]{2}\z/, allow_blank: true }
      end

      # @return [String] the address on one line, comma separated
      def one_line
        [line1, line2, locality, region, postcode, country].compact_blank.join(", ")
      end

      # @return [Array<String>] the address as lines, for a label
      def lines
        [line1, line2, [locality, region, postcode].compact_blank.join(" "), country].compact_blank
      end
    end
  end
end
