# frozen_string_literal: true

module EcsRails
  module Catalogue
    # Compares a declaration with live PostgreSQL metadata (ECS-29). It only
    # renders additions; a mismatch describes the explicit repair needed.
    # Application data and existing definitions are never changed here.
    class SchemaDiff
      # @param schema [Schema] the expected catalogue declaration
      # @param table_name [String, Symbol] the existing table
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @param slot_upgrade [Boolean] the preceding migration adds slot/index
      def initialize(schema, table_name:, connection:, slot_upgrade: false)
        @schema = schema
        @table = table_name.to_s
        @connection = connection
        @slot_upgrade = slot_upgrade
        @columns = connection.columns(@table).index_by(&:name)
        @indexes = connection.indexes(@table)
        @foreign_keys = connection.foreign_keys(@table)
      end

      # @param indent [Integer] spaces inside the generated change method
      # @return [String] additive source, or empty for a compatible table
      # @raise [SchemaMismatch] existing structure requires a reviewed repair
      def to_ruby(indent: 4)
        @additions = []
        @problems = []
        inspect_columns
        inspect_indexes
        inspect_foreign_keys
        unless @problems.empty?
          raise SchemaMismatch, "Catalogue schema mismatch:\n- #{@problems.join("\n- ")}\n" \
                                "Write and review an explicit repair/backfill migration, then rerun ecs_rails:upgrade. " \
                                "No column conversion or constraint replacement was generated."
        end
        @additions.map { |line| "#{' ' * indent}#{line}" }.join("\n")
      end

      private

      def required_columns
        [Schema::Column.new(:uuid, :id, null: false),
         Schema::Column.new(:uuid, :entity_id, null: false),
         Schema::Column.new(:string, :slot, null: false, default: ""),
         *@schema.columns,
         Schema::Column.new(:datetime, :created_at, null: false, precision: 6),
         Schema::Column.new(:datetime, :updated_at, null: false, precision: 6)]
      end

      def inspect_columns
        primary_key = @connection.primary_key(@table)
        mismatch("primary key", primary_key, "id") unless primary_key == "id"
        required_columns.each do |column|
          next if column.name == :slot && @slot_upgrade

          actual = @columns[column.name.to_s]
          if actual.nil?
            if %i[id entity_id].include?(column.name) || (!column.options.fetch(:null, true) && column.options[:default].nil?)
              @problems << "#{@table}.#{column.name} is missing; needs #{column.type} #{column.options.inspect} and an explicit backfill"
            else
              @additions << "add_column :#{@table}, :#{column.name}, :#{column.type}#{options(column.options)}"
            end
            next
          end

          expected = column_properties(column)
          observed = actual_properties(actual)
          expected.each do |property, value|
            mismatch("#{column.name} #{property}", observed[property], value) unless observed[property] == value
          end
        end
      end

      def column_properties(column)
        type = column.type == :bigint ? :integer : column.type
        properties = { type: type, null: column.options.fetch(:null, true),
                       array: column.options.fetch(:array, false), default: column.options[:default] }
        if column.name == :id
          properties[:default] = "gen_random_uuid()"
        end
        if %i[string integer].include?(type)
          properties[:limit] = column.options.fetch(:limit, type == :integer ? (column.type == :bigint ? 8 : 4) : nil)
        end
        if %i[decimal datetime].include?(type)
          properties[:precision] = column.options.fetch(:precision, type == :datetime ? 6 : nil)
        end
        properties[:scale] = column.options[:scale] if type == :decimal
        properties
      end

      def actual_properties(actual)
        default = if actual.default_function
                    actual.default_function.sub(/\A(?:public|pg_catalog)\./, "")
                  else
                    deserialize_default(actual)
                  end
        { type: actual.type, null: actual.null, array: actual.array, default: default,
          limit: actual.limit, precision: actual.type == :datetime ? (actual.precision || 6) : actual.precision,
          scale: actual.scale }
      end

      # Use registered attribute types without loading an application model or
      # populating its table/schema cache. PostgreSQL reports arrays and JSON
      # defaults as strings; comparing those strings to Ruby [] is incorrect.
      def deserialize_default(column)
        return nil if column.default.nil?
        return column.default if column.type == :tsvector

        modifiers = column.array ? { array: true } : {}
        ActiveRecord::Type.lookup(column.type, adapter: :postgresql, **modifiers)
                          .deserialize(column.default)
      end

      def inspect_indexes
        singleton = Schema::Index.new(%i[entity_id slot], unique: true)
        if @slot_upgrade
          legacy = Schema::Index.new([:entity_id], unique: true)
          unless @indexes.any? { |index| matching_index?(index, legacy) }
            @problems << "#{@table} pre-slot upgrade needs an unconditional unique index on entity_id; inspect legacy duplicates before repair"
          end
        else
          inspect_index(singleton)
        end
        @schema.indexes.each { |index| inspect_index(index) }
      end

      def inspect_index(expected)
        return if @indexes.any? { |actual| matching_index?(actual, expected) }

        name = expected.options[:name] || @connection.index_name(@table, column: expected.columns)
        conflicts = @indexes.select { |index| index.columns == expected.columns.map(&:to_s) || index.name == name }
        if conflicts.any?
          actual = conflicts.map { |index| "#{index.name} #{index_properties(index).inspect}" }.join(", ")
          mismatch("index #{expected.columns.inspect}", actual, expected_index_properties(expected))
        else
          @additions << "add_index :#{@table}, #{expected.columns.inspect}#{options(expected.options)}"
        end
      end

      def matching_index?(actual, expected)
        actual.columns == expected.columns.map(&:to_s) && index_properties(actual) == expected_index_properties(expected)
      end

      def index_properties(index)
        { unique: index.unique, using: index.using.to_s, where: predicate(index.where),
          order: index.orders.presence, opclass: index.opclasses.presence,
          nulls_not_distinct: !!index.nulls_not_distinct, valid: index.valid? }
      end

      def expected_index_properties(index)
        { unique: index.options.fetch(:unique, false), using: index.options.fetch(:using, :btree).to_s,
          where: predicate(index.options[:where]), order: index.options[:order].presence,
          opclass: index.options[:opclass].presence,
          nulls_not_distinct: index.options.fetch(:nulls_not_distinct, false), valid: true }
      end

      # The catalogue has one simple Boolean predicate. Recognize its normal
      # PostgreSQL spellings; do not guess equivalence for arbitrary SQL.
      def predicate(value)
        text = value.to_s.strip
        return nil if text.empty?
        return "exclusive" if text.match?(/\A\(*"?exclusive"?\s*(?:=\s*true|IS\s+TRUE)?\)*\z/i)

        text
      end

      def inspect_foreign_keys
        required = [Schema::ForeignKey.new(:entity_id, :cascade), *@schema.foreign_keys]
        required.each do |expected|
          candidates = @foreign_keys.select { |key| key.column == expected.column.to_s }
          properties = { to_table: "entities", primary_key: "id", on_delete: expected.on_delete,
                         on_update: nil, validate: true, deferrable: false }
          next if candidates.any? { |key| foreign_key_properties(key) == properties }

          if candidates.empty?
            @additions << "add_foreign_key :#{@table}, :entities, column: :#{expected.column}, on_delete: :#{expected.on_delete}"
          else
            mismatch("foreign key #{expected.column}", candidates.map { |key| foreign_key_properties(key) }, properties)
          end
        end
      end

      def foreign_key_properties(key)
        { to_table: key.to_table, primary_key: key.primary_key, on_delete: key.on_delete,
          on_update: key.on_update, validate: key.validate?, deferrable: !!key.deferrable }
      end

      def mismatch(subject, actual, expected)
        @problems << "#{@table}.#{subject}: found #{actual.inspect}; expected #{expected.inspect}"
      end

      def options(values)
        values.empty? ? "" : ", " + values.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
      end
    end
  end
end
