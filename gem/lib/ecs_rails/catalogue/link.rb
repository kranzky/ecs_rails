# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A URL with a label: website, github, webhook — one slot each.
    module Link
      extend Definition

      table "links"
      schema do |t|
        t.string :url,   default: nil
        t.string :label, default: nil
      end

      included do
        validates :url, format: { with: %r{\Ahttps?://\S+\z}, allow_nil: true }
      end

      # @return [String, nil] the host part of the URL
      def host
        URI.parse(url).host if url.present?
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
