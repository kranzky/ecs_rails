# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0017: the catalogue's mechanism (ADR-0018) — the schema
# declaration a catalogue module carries, what `include` does to the one-line
# app class, the registry of components and sets, and the two outputs one
# declaration has: a live table (`apply`) and migration source (`to_ruby`).
#
# The components' own behaviour is spec/catalogue/components_spec.rb.
RSpec.describe EcsRails::Catalogue do
  describe "the registry" do
    it "knows every catalogue component, in file order, Relationship and Marker first" do
      names = described_class.components.map(&:catalogue_name)

      aggregate_failures do
        expect(names.first(2)).to eq %i[relationship marker]
        expect(names).to include(:name, :email, :address, :text, :state, :money, :token, :search_vector)
        expect(names.size).to eq 25
      end
    end

    it "finds a component by catalogue name, class name or table" do
      aggregate_failures do
        expect(described_class[:money]).to be EcsRails::Catalogue::Money
        expect(described_class["CalendarDate"]).to be EcsRails::Catalogue::CalendarDate
        expect(described_class["addresses"]).to be EcsRails::Catalogue::Address
        expect(described_class[:nope]).to be_nil
      end
    end

    it "groups components into sets, core by default" do
      aggregate_failures do
        expect(described_class.sets).to eq %i[core commerce social saas]
        expect(described_class.in_sets(:commerce)).to eq [EcsRails::Catalogue::Money]
        expect(described_class.in_sets(:core)).not_to include(EcsRails::Catalogue::Money)
        expect(described_class.in_sets(:core).size).to eq 24
        expect(described_class.in_sets(:all)).to eq described_class.components
        expect(described_class.in_sets(:core, :commerce).size).to eq 25
      end
    end

    it "rejects an unknown set" do
      expect { described_class.in_sets(:premium) }.to raise_error(ArgumentError, /premium.*known: core/)
    end

    it "never names a component after a Ruby core constant" do
      shadowed = described_class.components.map(&:class_name).select { |n| Object.const_defined?(n) && Object.const_get(n).is_a?(Module) && !Object.const_get(n).ancestors.include?(EcsRails::Component) }

      expect(shadowed).to be_empty
    end
  end

  describe "a definition" do
    let(:money) { EcsRails::Catalogue::Money }

    it "carries its class name, table and set" do
      aggregate_failures do
        expect(money.catalogue_name).to eq :money
        expect(money.class_name).to eq "Money"
        expect(money.table).to eq "monies"
        expect(money.set).to eq :commerce
      end
    end

    it "derives the table from the name when none is declared" do
      mod = Module.new
      stub_const("EcsRails::Catalogue::Widget", mod)
      mod.extend EcsRails::Catalogue::Definition

      expect(mod.table).to eq "widgets"
      expect(mod.set).to eq :core
    ensure
      described_class.components.delete(mod)
    end

    it "sets the table name on the including class and runs its included block" do
      klass = Class.new(ApplicationComponent) { include EcsRails::Catalogue::Money }

      aggregate_failures do
        expect(klass.table_name).to eq "monies"
        expect(klass.new(currency: "usd")).not_to be_valid # the included block's validation
      end
    end

    it "lets the including class override the table name — the app owns it" do
      # This is exactly how the suite's CatalogueEmail is declared.
      expect(CatalogueEmail.table_name).to eq "catalogue_emails"
      expect(CatalogueEmail.new(address: "a@b.com").tap(&:valid?).errors[:address]).to be_empty
      expect(CatalogueEmail.new(address: "nope").tap(&:valid?).errors[:address]).to be_present
    end
  end

  describe "a schema declaration" do
    let(:schema) { EcsRails::Catalogue::Money.schema }

    it "records columns with their options" do
      expect(schema.columns.map(&:to_a)).to eq [
        [:integer, :amount_cents, { default: 0, null: false }],
        [:string, :currency, { default: "USD", null: false, limit: 3 }]
      ]
    end

    it "records indexes and foreign keys beyond the standard ones" do
      relationship = EcsRails::Catalogue::Relationship.schema

      aggregate_failures do
        expect(relationship.indexes.map(&:columns)).to eq [%i[target_id slot], %i[target_id slot owner_model]]
        expect(relationship.indexes.last.options).to include(unique: true, where: "exclusive")
        expect(relationship.foreign_keys.map(&:to_a)).to eq [[:target_id, :nullify]]
      end
    end

    it "only accepts the column types every supported PostgreSQL has" do
      expect { EcsRails::Catalogue::Schema.new { |t| t.hstore :x } }.to raise_error(NoMethodError)
    end

    it "renders migration source with the invariants every component table has" do
      source = schema.to_ruby(table_name: "monies")

      aggregate_failures do
        expect(source).to include('create_table :monies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|')
        expect(source).to include("t.uuid :entity_id, null: false")
        expect(source).to include('t.string :slot, null: false, default: ""')
        expect(source).to include("t.integer :amount_cents, default: 0, null: false")
        expect(source).to include('t.string :currency, default: "USD", null: false, limit: 3')
        expect(source).to include("t.timestamps")
        expect(source).to include("add_index :monies, [:entity_id, :slot], unique: true")
        expect(source).to include("add_foreign_key :monies, :entities, column: :entity_id, on_delete: :cascade")
      end
    end

    it "renders array and GIN options as Ruby literals" do
      source = EcsRails::Catalogue::Tags.schema.to_ruby(table_name: "tags")

      expect(source).to include("t.string :names, array: true, default: [], null: false")
      expect(source).to include("add_index :tags, :names, using: :gin")
    end

    it "renders only what is missing as a diff" do
      diff = schema.to_ruby_diff(table_name: "monies", existing_columns: %w[id entity_id slot amount_cents],
                                 existing_indexes: [%w[entity_id slot]])

      expect(diff.lines.map(&:strip)).to eq ['add_column :monies, :currency, :string, default: "USD", null: false, limit: 3']
    end

    it "renders an empty diff for a current table" do
      diff = schema.to_ruby_diff(table_name: "monies", existing_columns: %w[id entity_id slot amount_cents currency],
                                 existing_indexes: [%w[entity_id slot]])

      expect(diff).to eq ""
    end

    # THE guarantee ADR-0018 rests on: the suite's tables ARE the declarations.
    # If `apply` and `to_ruby` ever disagreed, the table a user's migration
    # creates would differ from the one the gem was tested against.
    it "applies to the live database as the same table the source describes" do
      connection = ActiveRecord::Base.connection
      columns = connection.columns("monies").to_h { |c| [c.name, [c.type, c.null]] }

      aggregate_failures do
        expect(columns["amount_cents"]).to eq [:integer, false]
        expect(columns["currency"]).to eq [:string, false]
        expect(Money.column_defaults.slice("amount_cents", "currency")).to eq("amount_cents" => 0, "currency" => "USD")
        expect(connection.indexes("monies").map(&:columns)).to include(%w[entity_id slot])
        expect(connection.foreign_keys("monies").map(&:to_table)).to eq ["entities"]
      end
    end

    it "created every catalogue table in the test database from the declarations" do
      connection = ActiveRecord::Base.connection
      tables = described_class.components.map(&:table).map { |t| %w[emails names addresses].include?(t) ? "catalogue_#{t}" : t }

      expect(connection.tables).to include(*tables)
    end
  end
end
