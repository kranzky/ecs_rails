# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A piece of text: title, body, bio, description — one slot each. The most
    # generic shape in the catalogue, and the one the forum rebuild judges
    # (`post.title_text`).
    module Text
      extend Definition

      table "texts"
      schema do |t|
        t.text :value, default: nil
      end

      # @return [String] the value, or ""
      def to_s
        value.to_s
      end

      # @return [Integer] word count
      def words
        value.to_s.split.size
      end
    end
  end
end
