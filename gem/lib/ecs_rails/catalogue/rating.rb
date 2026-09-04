# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A rating of one to five stars.
    module Rating
      extend Definition

      table "ratings"
      primary_attribute :stars
      schema do |t|
        t.integer :stars, default: nil
      end

      included do
        validates :stars, inclusion: { in: 1..5 }, allow_nil: true
      end

      # @return [Boolean]
      def rated?
        stars.present?
      end
    end
  end
end
