# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module EcsRails
  # The catalogue: standard components that ship in the gem (ADR-0018).
  #
  # Each catalogue component is a module in this namespace — `Catalogue::Money`,
  # `Catalogue::Address` — carrying its behaviour, its validations and a
  # **schema declaration** the generators read. A host application owns the
  # constant and includes the module into a one-line class:
  #
  #   class Money < ApplicationComponent
  #     include EcsRails::Catalogue::Money
  #   end
  #
  # `rails g ecs_rails:install` writes those classes and ONE migration creating
  # every catalogue table, so that after install and one `db:migrate` an
  # application is built from the catalogue without another migration. The
  # tables exist; a slot names the role (`component Text, prefix: :title`).
  # `rails g ecs_rails:upgrade` diffs these declarations against the database
  # when the gem is upgraded.
  #
  # Components are grouped into **sets** so a prototype need not carry every
  # table: `core` (the default), `commerce`, and `social` / `saas` (named,
  # empty in 0.3.0). See ADR-0018 §5 for the shelf.
  #
  # The one rule on names: never shadow a Ruby core constant (`Date`, `Time`,
  # `Set`, `Range`) — hence `CalendarDate`. Where a name collides with a gem the
  # application uses (`Money`), the one-line class is the remedy:
  # `class Price < ApplicationComponent; include EcsRails::Catalogue::Money; end`.
  module Catalogue
    # A recorded schema declaration: the columns a catalogue table has beyond
    # the ones every component table has (`id`, `entity_id`, `slot`, timestamps),
    # plus any extra indexes and foreign keys.
    #
    # One declaration, two outputs. {#apply} creates the table on a live
    # connection — the gem's own test schema is built this way — and {#to_ruby}
    # renders the equivalent migration source for the install and upgrade
    # generators. Because both read the same recording, the migration a user
    # runs and the table the gem was tested against cannot drift (ADR-0018:
    # "the schema declaration is the single source of truth for the table").
    class Schema
      # A declared column: `type` (Symbol, an ActiveRecord column type), `name`
      # (Symbol) and `options` (Hash — `default:`, `null:`, `limit:`, `array:`, ...).
      Column = Struct.new(:type, :name, :options)

      # A declared index beyond the standard `(entity_id, slot)` one: `columns`
      # (Array<Symbol>) and `options` (Hash — `unique:`, `using:`, `where:`, `name:`).
      Index = Struct.new(:columns, :options)

      # A declared foreign key to `entities` beyond the cascading `entity_id`
      # one: `column` (Symbol) and `on_delete` (`:cascade` or `:nullify`).
      ForeignKey = Struct.new(:column, :on_delete)

      # The column types a declaration may use. Kept to what every supported
      # PostgreSQL has and ActiveRecord maps natively, so a catalogue table
      # never needs an extension the install migration did not enable.
      COLUMN_TYPES = %i[
        string text integer bigint float decimal boolean date datetime uuid jsonb tsvector
      ].freeze

      # The recorder the `schema` block yields as `t`. It answers the column
      # types like a migration's table definition does, and records rather than
      # executes.
      class Recorder
        def initialize(schema)
          @schema = schema
        end

        COLUMN_TYPES.each do |type|
          define_method(type) do |name, **options|
            @schema.columns << Column.new(type, name.to_sym, options)
          end
        end

        # An index beyond the `(entity_id, slot)` one every table gets.
        #
        # @param columns [Array<Symbol>, Symbol]
        # @param options [Hash] `unique:`, `using:`, `where:`, `name:`
        # @return [void]
        def index(columns, **options)
          @schema.indexes << Index.new(Array(columns).map(&:to_sym), options)
        end

        # A foreign key to `entities` beyond the cascading `entity_id` one.
        #
        # @param column [Symbol] the referencing column
        # @param on_delete [Symbol] `:cascade` or `:nullify`
        # @return [void]
        def foreign_key(column, on_delete:)
          @schema.foreign_keys << ForeignKey.new(column.to_sym, on_delete)
        end
      end

      # @return [Array<Column>]
      attr_reader :columns
      # @return [Array<Index>]
      attr_reader :indexes
      # @return [Array<ForeignKey>]
      attr_reader :foreign_keys

      # @yieldparam t [Recorder] the recorder to declare columns and indexes on
      def initialize
        @columns = []
        @indexes = []
        @foreign_keys = []
        yield Recorder.new(self) if block_given?
      end

      # Creates the table on `target` — anything answering `create_table`,
      # `add_index` and `add_foreign_key`: an `ActiveRecord::Schema.define`
      # block's receiver, a migration, or a connection.
      #
      # Every catalogue table gets the invariants of architecture.md §2 — UUID
      # primary key, non-null `entity_id`, `slot` defaulting to `""`, a unique
      # index on `(entity_id, slot)`, a cascading foreign key to `entities` —
      # and then whatever the declaration added.
      #
      # @param target [#create_table] where to create it
      # @param table_name [String, Symbol] the table to create
      # @param force [Boolean, Symbol] `create_table`'s `force:` — `:cascade`
      #   drops an existing table first; a test schema wants that, a migration
      #   never does
      # @return [void]
      def apply(target, table_name:, force: false)
        table_name = table_name.to_sym
        target.create_table(table_name, id: :uuid, default: -> { "gen_random_uuid()" }, force: force) do |t|
          t.uuid :entity_id, null: false
          t.string :slot, null: false, default: ""
          columns.each { |column| t.public_send(column.type, column.name, **column.options) }
          t.timestamps
        end
        target.add_index(table_name, %i[entity_id slot], unique: true)
        indexes.each { |index| target.add_index(table_name, index.columns, **index.options) }
        target.add_foreign_key(table_name, :entities, column: :entity_id, on_delete: :cascade)
        foreign_keys.each do |fk|
          target.add_foreign_key(table_name, :entities, column: fk.column, on_delete: fk.on_delete)
        end
      end

      # The migration source that does what {#apply} does, for the generators'
      # templates. Indented to sit inside a migration's `def change`.
      #
      # @param table_name [String, Symbol]
      # @param indent [Integer] leading spaces
      # @return [String]
      def to_ruby(table_name:, indent: 4)
        pad = " " * indent
        lines = []
        lines << "#{pad}create_table :#{table_name}, id: :uuid, default: -> { \"gen_random_uuid()\" } do |t|"
        lines << "#{pad}  t.uuid :entity_id, null: false"
        lines << "#{pad}  t.string :slot, null: false, default: \"\""
        columns.each do |column|
          lines << "#{pad}  t.#{column.type} :#{column.name}#{render_options(column.options)}"
        end
        lines << "#{pad}  t.timestamps"
        lines << "#{pad}end"
        lines << "#{pad}add_index :#{table_name}, [:entity_id, :slot], unique: true"
        indexes.each do |index|
          cols = index.columns.size == 1 ? ":#{index.columns.first}" : "[#{index.columns.map { |c| ":#{c}" }.join(', ')}]"
          lines << "#{pad}add_index :#{table_name}, #{cols}#{render_options(index.options)}"
        end
        lines << "#{pad}add_foreign_key :#{table_name}, :entities, column: :entity_id, on_delete: :cascade"
        foreign_keys.each do |fk|
          lines << "#{pad}add_foreign_key :#{table_name}, :entities, column: :#{fk.column}, on_delete: :#{fk.on_delete}"
        end
        lines.join("\n")
      end

      # The `add_column` / `add_index` source that brings an existing table up to
      # this declaration, given what the table already has. Empty when nothing
      # is missing. Used by `ecs_rails:upgrade` for a catalogue table that exists
      # but predates a column or index added in a later gem version.
      #
      # @param table_name [String, Symbol]
      # @param existing_columns [Array<String>] the table's current column names
      # @param existing_indexes [Array<Array<String>>] each index's column names
      # @param indent [Integer]
      # @return [String] possibly empty
      def to_ruby_diff(table_name:, existing_columns:, existing_indexes:, indent: 4)
        pad = " " * indent
        lines = []
        columns.each do |column|
          next if existing_columns.include?(column.name.to_s)

          lines << "#{pad}add_column :#{table_name}, :#{column.name}, :#{column.type}#{render_options(column.options)}"
        end
        indexes.each do |index|
          next if existing_indexes.include?(index.columns.map(&:to_s))

          cols = index.columns.size == 1 ? ":#{index.columns.first}" : "[#{index.columns.map { |c| ":#{c}" }.join(', ')}]"
          lines << "#{pad}add_index :#{table_name}, #{cols}#{render_options(index.options)}"
        end
        lines.join("\n")
      end

      private

      # `, default: "", null: false` — options as they would be typed. Symbols,
      # strings, numbers, booleans, nil and arrays render with `inspect`, which
      # is exactly their Ruby literal.
      def render_options(options)
        return "" if options.empty?

        ", " + options.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
      end
    end

    # Extended into each catalogue component module. Gives the module the
    # declaration DSL — `table`, `set`, `schema`, `included` — registers it in
    # the catalogue, and makes `include EcsRails::Catalogue::Money` into a class
    # set the table name and run the module's `included` block, the way an
    # ActiveSupport::Concern would.
    #
    #   module EcsRails::Catalogue::Money
    #     extend EcsRails::Catalogue::Definition
    #
    #     table "monies"
    #     set :commerce
    #     schema do |t|
    #       t.integer :amount_cents, null: false, default: 0
    #       t.string  :currency,     null: false, default: "USD", limit: 3
    #     end
    #
    #     included do
    #       validates :currency, format: /\A[A-Z]{3}\z/
    #     end
    #
    #     def +(other) = ...
    #   end
    #
    # Not an ActiveSupport::Concern, deliberately: a concern's `included` block
    # has no handle on *which* concern is being included, and the table name is
    # per catalogue component. `Module#included(base)` does.
    module Definition
      # Registers the module with the catalogue as it is defined.
      #
      # @api private
      def self.extended(mod)
        Catalogue.register(mod)
      end

      # The module's short name, as a Symbol: `:money`, `:calendar_date`. Also
      # the default class name's underscore form and the file name install
      # writes.
      #
      # @return [Symbol]
      def catalogue_name
        name.demodulize.underscore.to_sym
      end

      # The default app class name: `"Money"`, `"CalendarDate"`.
      #
      # @return [String]
      def class_name
        name.demodulize
      end

      # Declares or reads the table name. Set once in the module body; the
      # including class may still override it (`self.table_name = ...`) after
      # the include, which is how an app whose `emails` table is already taken
      # keeps the catalogue component — the app owns the table name too.
      #
      # @param name [String, nil]
      # @return [String]
      def table(name = nil)
        @table = name.to_s if name
        @table || class_name.underscore.pluralize
      end

      # Declares or reads the set. `:core` when not declared.
      #
      # @param name [Symbol, nil]
      # @return [Symbol]
      def set(name = nil)
        @set = name.to_sym if name
        @set || :core
      end

      # Declares (or reads) the component's primary attribute — the one a
      # labelled slot stands for, so `component Text, prefix: :title` also
      # delegates `post.title` (see EcsRails::Slots::Component::ClassMethods#primary).
      # Applied to the including class at include time.
      #
      # @param name [Symbol, nil]
      # @return [Symbol, nil]
      def primary_attribute(name = nil)
        @primary_attribute = name.to_sym if name
        @primary_attribute
      end

      # Declares (with a block) or reads the schema.
      #
      # @yieldparam t [Schema::Recorder]
      # @return [Schema]
      def schema(&block)
        @schema = Schema.new(&block) if block
        @schema ||= Schema.new
      end

      # With a block: records what to run in the including class — validations,
      # `slot_option`s, associations — exactly as a concern's `included` does.
      # Without one, it is Ruby's own include hook: sets the table name and runs
      # that block.
      #
      # @param base [Class, nil]
      # @return [void]
      def included(base = nil, &block)
        if block
          @included_block = block
          return
        end

        base.table_name = table
        base.primary(primary_attribute) if primary_attribute
        base.class_eval(&@included_block) if @included_block
      end
    end

    class << self
      # Every catalogue component, in definition (file) order.
      #
      # @return [Array<Module>]
      def components
        @components ||= []
      end

      # Records a catalogue module as it is defined ({Definition.extended}).
      #
      # @param mod [Module]
      # @return [void]
      # @api private
      def register(mod)
        components << mod unless components.include?(mod)
      end

      # The catalogue component named `name`, by catalogue name, class name or
      # table.
      #
      # @param name [Symbol, String]
      # @return [Module, nil]
      def [](name)
        key = name.to_s
        components.find do |mod|
          mod.catalogue_name.to_s == key || mod.class_name == key || mod.table == key
        end
      end

      # The set names, in the order they first appear.
      #
      # @return [Array<Symbol>]
      def sets
        (components.map(&:set) + %i[core commerce social saas]).uniq
      end

      # The components in the given sets, in catalogue order.
      #
      # @param names [Array<Symbol, String>] set names; `:all` for everything
      # @return [Array<Module>]
      # @raise [ArgumentError] for an unknown set
      def in_sets(*names)
        names = names.flatten.map(&:to_sym)
        return components.dup if names.include?(:all)

        unknown = names - sets
        raise ArgumentError, "unknown catalogue set#{'s' if unknown.size > 1}: #{unknown.join(', ')}; " \
                             "known: #{sets.join(', ')}" unless unknown.empty?

        components.select { |mod| names.include?(mod.set) }
      end

      # Creates every catalogue table (or those of the given sets) on `target`.
      # The gem's test schema is built this way.
      #
      # @param target [#create_table]
      # @param sets [Array<Symbol>, Symbol] default every set
      # @param except [Array<Module, Symbol>] components to skip
      # @param force [Boolean, Symbol] passed to {Schema#apply}
      # @return [void]
      def create_tables(target, sets: :all, except: [], force: false)
        skipped = except.map { |c| c.is_a?(Module) ? c : self[c] }
        in_sets(sets).each do |mod|
          next if skipped.include?(mod)

          mod.schema.apply(target, table_name: mod.table, force: force)
        end
      end
    end
  end
end

require "ecs_rails/catalogue/relationship"
require "ecs_rails/catalogue/marker"
require "ecs_rails/catalogue/name"
require "ecs_rails/catalogue/email"
require "ecs_rails/catalogue/password"
require "ecs_rails/catalogue/phone"
require "ecs_rails/catalogue/address"
require "ecs_rails/catalogue/geolocation"
require "ecs_rails/catalogue/link"
require "ecs_rails/catalogue/text"
require "ecs_rails/catalogue/identifier"
require "ecs_rails/catalogue/counter"
require "ecs_rails/catalogue/rating"
require "ecs_rails/catalogue/timestamp"
require "ecs_rails/catalogue/calendar_date"
require "ecs_rails/catalogue/period"
require "ecs_rails/catalogue/position"
require "ecs_rails/catalogue/state"
require "ecs_rails/catalogue/tags"
require "ecs_rails/catalogue/search_vector"
require "ecs_rails/catalogue/discard"
require "ecs_rails/catalogue/image"
require "ecs_rails/catalogue/role"
require "ecs_rails/catalogue/token"
require "ecs_rails/catalogue/money"
