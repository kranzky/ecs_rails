# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A piece of text: title, body, bio, description — one slot each. The most
    # generic shape in the catalogue. `value` is the primary attribute, so
    # `component Text, prefix: :title` reads and writes as `post.title` — the
    # slot name is the field name — while `post.title_text` is the component.
    module Text
      extend Definition

      table "texts"
      primary_attribute :value
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
