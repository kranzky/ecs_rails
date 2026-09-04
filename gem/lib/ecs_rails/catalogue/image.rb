# frozen_string_literal: true

module EcsRails
  module Catalogue
    # An image by URL with alt text: avatar, logo — one slot each. When Active
    # Storage is loaded in the application the class also gains
    # `has_one_attached :file`, so an upload can back the URL.
    module Image
      extend Definition

      table "images"
      schema do |t|
        t.string :url, default: nil
        t.string :alt, default: nil
      end

      included do
        validates :url, format: { with: %r{\Ahttps?://\S+\z}, allow_nil: true }
        has_one_attached :file if respond_to?(:has_one_attached)
      end

      # @return [Boolean]
      def present_url?
        url.present?
      end
    end
  end
end
