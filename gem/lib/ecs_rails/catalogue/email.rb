# frozen_string_literal: true

module EcsRails
  module Catalogue
    # An email address with a verification flag.
    #
    # Format is a regex, not a delivery check; `verified` is yours to flip
    # (`verify!`) when a confirmation link is followed.
    module Email
      extend Definition

      table "emails"
      schema do |t|
        t.string  :address,  default: nil
        t.boolean :verified, default: false, null: false
      end

      included do
        validates :address, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
      end

      # Marks the address verified and saves.
      #
      # @return [true]
      def verify!
        update!(verified: true)
      end

      # @return [String, nil] the domain part, e.g. "example.com"
      def domain
        address&.split("@", 2)&.last
      end
    end
  end
end
