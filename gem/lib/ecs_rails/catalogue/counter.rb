# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A count: likes, stock, quantity — one slot each. `increment!` and
    # `decrement!` write an atomic `UPDATE ... SET count = count + n` once the
    # row exists.
    module Counter
      extend Definition

      table "counters"
      schema do |t|
        t.integer :count, default: 0, null: false
      end

      # Adds `by` and saves. Atomic on a persisted row.
      #
      # @param by [Integer]
      # @return [Integer] the new count
      def increment!(by = 1)
        if persisted?
          self.class.where(id: id).update_all(["count = count + ?", by])
          reload
        else
          self.count = count + by
          save!
        end
        count
      end

      # Subtracts `by` and saves.
      #
      # @param by [Integer]
      # @return [Integer] the new count
      def decrement!(by = 1)
        increment!(-by)
      end

      # @return [Boolean]
      def zero?
        count.zero?
      end
    end
  end
end
