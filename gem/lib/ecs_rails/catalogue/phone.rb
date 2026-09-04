# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A phone number in E.164 (`+61412345678`), with an optional extension.
    # Multi-role by nature: `component Phone, prefix: :mobile`, `prefix: :work`.
    #
    # Format is the E.164 shape (a plus, a non-zero digit, up to 14 more) — no
    # country database, no dependency.
    module Phone
      extend Definition

      table "phones"
      schema do |t|
        t.string :e164,      default: nil, limit: 16
        t.string :extension, default: nil, limit: 8
      end

      included do
        validates :e164, format: { with: /\A\+[1-9]\d{1,14}\z/, allow_blank: true }
        validates :extension, format: { with: /\A\d+\z/, allow_blank: true }
      end

      # @return [String] the number with the extension, e.g. "+61812345678 x204"
      def to_s
        [e164, extension.presence && "x#{extension}"].compact.join(" ")
      end
    end
  end
end
