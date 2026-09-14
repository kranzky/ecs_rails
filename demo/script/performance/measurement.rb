# frozen_string_literal: true

module PerformanceComparison
  module Measurement
    module_function

    def sample
      queries = { reads: 0, writes: 0, transactions: 0, schema: 0, other: 0, cached: 0 }
      listener = lambda do |*arguments|
        payload = arguments.last
        category = if payload[:cached]
          :cached
        elsif payload[:name] == "SCHEMA"
          :schema
        else
          case payload[:sql].lstrip
          when /\ASELECT\b/i then :reads
          when /\A(?:INSERT|UPDATE|DELETE)\b/i then :writes
          when /\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i then :transactions
          else :other
          end
        end
        queries[category] += 1
      end
      result = nil
      measurement = nil
      # Keep GC enabled during the operation; force a collection outside it so
      # each sample starts without garbage left by setup or the previous call.
      GC.start
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
          allocated = GC.stat(:total_allocated_objects)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = yield
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          measurement = { milliseconds: elapsed * 1000,
                          allocated_objects: GC.stat(:total_allocated_objects) - allocated,
                          sql: queries }
        end
      end
      [measurement, result]
    end

    def distribution(values)
      sorted = values.sort
      { min: sorted.first, p50: sorted[(sorted.size * 0.50).ceil - 1],
        p95: sorted[(sorted.size * 0.95).ceil - 1], max: sorted.last }
    end

    def run(representation, name, warmups:, samples:)
      workload = Workloads.new(representation)
      measurements = []
      (1 + warmups + samples).times do
        workload.prepare_checkout if name == "checkout"
        measurement, result = sample { workload.public_send(name) }
        if name == "checkout"
          raise "checkout did not commit" if ActiveRecord::Base.connection.transaction_open?
          raise "order missing after checkout" unless result.class.exists?(result.id)
        end
        measurements << measurement
      end
      warm = measurements.drop(1 + warmups)
      { representation: representation, workload: name, first_call: measurements.first,
        warmups: measurements.slice(1, warmups), samples: warm,
        summary: { milliseconds: distribution(warm.map { |row| row[:milliseconds] }),
                   allocated_objects: distribution(warm.map { |row| row[:allocated_objects] }),
                   sql: warm.first.fetch(:sql).keys.to_h do |key|
                     [key, distribution(warm.map { |row| row[:sql].fetch(key) })]
                   end } }
    end

    def storage
      connection = ActiveRecord::Base.connection
      connection.select_all(<<~SQL).to_a.group_by { |row| row.fetch("table").start_with?("bench_") ? "plain" : "ecs" }
        SELECT relname AS table, pg_table_size(oid) AS table_bytes,
               pg_indexes_size(oid) AS index_bytes, pg_total_relation_size(oid) AS total_bytes
        FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
          AND relname NOT IN ('schema_migrations', 'ar_internal_metadata')
        ORDER BY relname
      SQL
    end

    def schema
      connection = ActiveRecord::Base.connection
      connection.tables.sort.to_h do |table|
        [table, { columns: connection.columns(table).map { |column| { name: column.name, type: column.sql_type, null: column.null, default: column.default } },
                  indexes: connection.indexes(table).map { |index| { name: index.name, columns: index.columns, unique: index.unique, using: index.using, where: index.where } },
                  foreign_keys: connection.foreign_keys(table).map { |key| { column: key.column, target: key.to_table, on_delete: key.on_delete } } }]
      end
    end
  end
end
