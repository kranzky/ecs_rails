# frozen_string_literal: true

require_relative "generator_helper"

# A migration that reads correctly but raises is a failure. These examples
# generate into a tmp dir and then actually EXECUTE the emitted SQL against
# rorecs_test, asserting on the real catalog rather than on the file's text.
#
# Isolation: everything happens in a scratch schema created inside the
# transaction spec_helper.rb already wraps every example in, so the whole lot —
# schema, tables, rows — is rolled back afterwards. The scratch schema is put
# first on the search_path so `create_table :entities` lands there rather than
# colliding with the real `entities` table the test schema already defines.
RSpec.describe "generated migrations actually run", type: :generator do
  # A method rather than a constant: a constant assigned inside this block would
  # land on Object and leak into every other spec file.
  def scratch_schema
    "rorecs_gen_check"
  end

  def connection
    ActiveRecord::Base.connection
  end

  # Runs a specific generator class, since this file exercises both.
  def generate(generator_class, args)
    generator = generator_class.new(args, {}, destination_root: destination_root)
    silence_stream { generator.invoke_all }
  end

  def run_migration(suffix, class_name)
    path = migration_paths(suffix).first
    raise "no migration matching #{suffix}" if path.nil?

    load path
    silence_stream { Object.const_get(class_name).new.migrate(:up) }
  end

  before do
    ActiveRecord::Migration.verbose = false
    connection.execute("CREATE SCHEMA #{scratch_schema}")
    connection.execute("SET LOCAL search_path TO #{scratch_schema}, public")

    generate(Rorecs::Generators::InstallGenerator, [])
    generate(Rorecs::Generators::ComponentGenerator, %w[Email address:string verified:boolean])

    run_migration("rorecs_create_entities", "RorecsCreateEntities")
    run_migration("create_emails", "CreateEmails")
  end

  # No `after` cleanup: the transaction spec_helper.rb wraps every example in
  # rolls the scratch schema away. An explicit teardown statement would itself
  # fail in the examples that deliberately abort the transaction below.

  # Runs a statement expected to violate a constraint, inside a savepoint, so
  # the violation does not poison the surrounding transaction.
  def violating
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  end

  def columns_of(table)
    connection.select_all(<<~SQL).to_a
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = '#{scratch_schema}' AND table_name = '#{table}'
    SQL
  end

  describe "the entities table" do
    it "is created" do
      names = columns_of("entities").map { |c| c["column_name"] }
      expect(names).to contain_exactly("id", "model", "created_at")
    end

    it "has a uuid primary key defaulting to gen_random_uuid()" do
      id = columns_of("entities").find { |c| c["column_name"] == "id" }

      aggregate_failures do
        expect(id["data_type"]).to eq("uuid")
        expect(id["column_default"]).to match(/gen_random_uuid\(\)/)
      end
    end

    it "makes model non-null" do
      model = columns_of("entities").find { |c| c["column_name"] == "model" }
      expect(model["is_nullable"]).to eq("NO")
    end

    it "indexes model" do
      indexes = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'entities'"
      )
      expect(indexes).to include(match(/\(model\)/))
    end

    # architecture.md §1 — entities are immutable.
    it "has no updated_at" do
      names = columns_of("entities").map { |c| c["column_name"] }
      expect(names).not_to include("updated_at")
    end
  end

  describe "the component table" do
    it "makes entity_id a non-null uuid" do
      entity_id = columns_of("emails").find { |c| c["column_name"] == "entity_id" }

      aggregate_failures do
        expect(entity_id["data_type"]).to eq("uuid")
        expect(entity_id["is_nullable"]).to eq("NO")
      end
    end

    it "applies the explicit defaults" do
      cols = columns_of("emails")
      address = cols.find { |c| c["column_name"] == "address" }
      verified = cols.find { |c| c["column_name"] == "verified" }

      aggregate_failures do
        expect(address["column_default"]).to be_nil
        expect(verified["column_default"]).to eq("false")
      end
    end

    # ADR-0005, proven against the catalog rather than the file text.
    it "creates a UNIQUE index on entity_id" do
      indexes = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'emails'"
      )
      expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id\)/))
    end

    it "creates a foreign key to entities with ON DELETE CASCADE" do
      # confdeltype 'c' is ON DELETE CASCADE.
      delete_rules = connection.select_values(<<~SQL)
        SELECT c.confdeltype
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = '#{scratch_schema}' AND t.relname = 'emails' AND c.contype = 'f'
      SQL

      expect(delete_rules).to eq(["c"])
    end
  end

  # The invariants are only worth anything if the database enforces them.
  describe "the invariants, enforced" do
    def create_entity
      connection.select_value(
        "INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id"
      )
    end

    it "rejects a second component row for the same entity" do
      entity_id = create_entity
      connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      expect do
        violating do
          connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rejects a component row with no entity" do
      expect do
        violating do
          connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES (NULL, now(), now())")
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "rejects a component row pointing at a non-existent entity" do
      expect do
        violating do
          connection.execute(
            "INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{SecureRandom.uuid}', now(), now())"
          )
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "cascades a deleted entity to its component rows" do
      entity_id = create_entity
      connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      connection.execute("DELETE FROM entities WHERE id = '#{entity_id}'")

      expect(connection.select_value("SELECT count(*) FROM emails").to_i).to eq(0)
    end

    it "applies the boolean default on insert" do
      entity_id = create_entity
      connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      expect(connection.select_value("SELECT verified FROM emails")).to be(false)
    end
  end
end
