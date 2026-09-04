# frozen_string_literal: true

module EcsRails
  module Catalogue
    # Soft delete as presence: an entity is discarded when its Discard row
    # exists with a time. `Post.without_component(Discard)` is "kept".
    module Discard
      extend Definition

      table "discards"
      schema do |t|
        t.datetime :discarded_at, default: nil
      end

      # Stamps `discarded_at` and saves.
      #
      # @return [Time]
      def discard!
        update!(discarded_at: Time.current)
        discarded_at
      end

      # Destroys the row, so the entity reads as kept again.
      #
      # @return [void]
      def undiscard!
        destroy if persisted?
      end

      # @return [Boolean]
      def discarded?
        discarded_at.present?
      end
    end
  end
end
