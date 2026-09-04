# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A state machine: a `status` and an optional `transitions` log. The
    # vocabulary belongs to the declaring entity, not the component:
    #
    #   class Order < ApplicationEntity
    #     component State, prefix: :fulfilment, states: %w[pending paid shipped], history: true
    #   end
    #
    #   order.fulfilment_state.transition!("paid", event: "checkout")
    #   order.fulfilment_state.status         # => "paid"
    #   order.fulfilment_state.transitions    # => [{ "at" => ..., "from" => "pending", "to" => "paid", "event" => "checkout" }]
    #
    # `states:` — the allowed values; empty means any. `history:` — whether
    # `transition!` appends to the log (default true); `history: false` makes a
    # slot a plain enum (visibility, priority, severity) on the same table.
    module State
      extend Definition

      table "states"
      schema do |t|
        t.string :status,      default: nil
        t.jsonb  :transitions, default: [], null: false
      end

      included do
        slot_option :states,  default: []
        slot_option :history, default: true
        validate :ecs_status_in_vocabulary
      end

      # Moves to `to`, logging the transition when `history` is on, and saves.
      #
      # @param to [String, Symbol] the new status
      # @param event [String, Symbol, nil] a label for the log
      # @return [String] the new status
      # @raise [ArgumentError] if `to` is not in the slot's `states:`
      def transition!(to, event: nil)
        to = to.to_s
        unless states.empty? || states.map(&:to_s).include?(to)
          raise ArgumentError, "#{to.inspect} is not one of #{states.inspect} (slot #{slot.inspect})"
        end

        if history
          entry = { "at" => Time.current.iso8601, "from" => status, "to" => to }
          entry["event"] = event.to_s if event
          self.transitions = transitions + [entry]
        end
        self.status = to
        save!
        status
      end

      # @param value [String, Symbol]
      # @return [Boolean]
      def in?(value)
        status == value.to_s
      end

      private

      def ecs_status_in_vocabulary
        return if status.nil? || states.empty? || states.map(&:to_s).include?(status)

        errors.add(:status, "must be one of #{states.join(', ')}")
      end
    end
  end
end
