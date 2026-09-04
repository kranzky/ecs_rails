# frozen_string_literal: true

module EcsRails
  module Catalogue
    # Free tagging: an array of strings. An unbounded set of *strings* is a
    # value, not a collection of entities. `allow:` on the declaration
    # restricts the vocabulary.
    #
    #   component Tags, prefix: :topics, allow: %w[ruby rails ecs]
    #   post.topics_tags.add("ruby")
    #   Post.with_component(Tags, prefix: :topics).merge(Tags.tagged("ruby"))
    module Tags
      extend Definition

      table "tags"
      schema do |t|
        t.string :names, array: true, default: [], null: false
        t.index :names, using: :gin
      end

      included do
        slot_option :allow, default: nil
        validate :ecs_names_allowed

        # Rows tagged with `name`.
        #
        # @param name [String]
        # @return [ActiveRecord::Relation]
        scope :tagged, ->(name) { where("? = ANY (names)", name.to_s) }
      end

      # Adds names, de-duplicated, and returns the array.
      #
      # @param new_names [Array<String>]
      # @return [Array<String>]
      def add(*new_names)
        self.names = (names + new_names.flatten.map(&:to_s)).uniq
      end

      # Removes names and returns the array.
      #
      # @param gone [Array<String>]
      # @return [Array<String>]
      def remove(*gone)
        self.names = names - gone.flatten.map(&:to_s)
      end

      # @param name [String]
      # @return [Boolean]
      def tagged?(name)
        names.include?(name.to_s)
      end

      private

      def ecs_names_allowed
        return if allow.nil?

        disallowed = names - allow.map(&:to_s)
        errors.add(:names, "#{disallowed.join(', ')} not allowed (allowed: #{allow.join(', ')})") if disallowed.any?
      end
    end
  end
end
