# frozen_string_literal: true

module Demo
  # Sequential identifiers without another migration. Each series has a fixed
  # PostgreSQL advisory lock held until the caller commits the inserted number.
  # The unique Identifier index remains the backstop for uncoordinated writers.
  module Numbering
    SERIES = { "order_number" => [1, "ORD"], "invoice_number" => [2, "INV"] }.freeze
    LOCK_NAMESPACE = 28_025

    module_function

    def next(slot, prefix)
      key, expected_prefix = SERIES.fetch(slot)
      raise ArgumentError, "unexpected document prefix" unless prefix == expected_prefix

      Identifier.connection_pool.with_connection do |connection|
        raise ArgumentError, "allocate and save document numbers in one transaction" unless connection.transaction_open?

        connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{key})")
        # Text MAX puts 999999 after 1000000. Only this series' numeric suffix
        # participates, so six digits is padding, not an allocation limit.
        last = Identifier.where(slot: slot).where("value ~ ?", "^#{prefix}-[0-9]+$")
                         .maximum(Arel.sql("split_part(value, '-', 2)::bigint")) || 0
        format("%s-%06d", prefix, last + 1)
      end
    end
  end
end
