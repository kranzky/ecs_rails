# frozen_string_literal: true

require_relative "generator_helper"

# A migration that reads correctly but raises is a failure. These examples
# generate into a tmp dir and then actually EXECUTE the emitted SQL against
# ecs_rails_test, asserting on the real catalog rather than on the file's text.
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
    "ecs_rails_gen_check"
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

    generate(EcsRails::Generators::InstallGenerator, [])
    generate(EcsRails::Generators::ComponentGenerator, %w[Email address:string verified:boolean])

    run_migration("ecs_rails_create_entities", "EcsRailsCreateEntities")
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

    # ADR-0005 / ADR-0015, proven against the catalog rather than the file text.
    it "creates a UNIQUE index on (entity_id, slot)" do
      indexes = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'emails'"
      )
      expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
    end

    it "gives slot a non-null empty-string default" do
      slot = columns_of("emails").find { |c| c["column_name"] == "slot" }

      aggregate_failures do
        expect(slot["is_nullable"]).to eq("NO")
        expect(slot["column_default"]).to match(/''/)
      end
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

    it "rejects a second component row for the same entity and slot" do
      entity_id = create_entity
      connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      expect do
        violating do
          connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # RFC-0014 / ADR-0015: the same component in another slot is a second row.
    it "accepts a second row for the same entity in a different slot" do
      entity_id = create_entity
      connection.execute("INSERT INTO emails (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")
      connection.execute(
        "INSERT INTO emails (entity_id, slot, created_at, updated_at) VALUES ('#{entity_id}', 'work', now(), now())"
      )

      expect(connection.select_value("SELECT count(*) FROM emails").to_i).to eq(2)
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

  # RFC-0012 / ADR-0013: the relationship migration, executed against the real
  # catalog. The point is the asymmetric FK delete rules — entity_id CASCADE,
  # target NULLIFY — and that the database actually enforces the nullify.
  describe "the relationship migration" do
    before do
      generate(EcsRails::Generators::RelationshipGenerator, %w[Post author:User])
      run_migration("create_post_authors", "CreatePostAuthors")
    end

    def delete_rule_for(column)
      connection.select_value(<<~SQL)
        SELECT c.confdeltype
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE n.nspname = '#{scratch_schema}' AND t.relname = 'post_authors'
          AND c.contype = 'f' AND a.attname = '#{column}'
      SQL
    end

    it "cascades on the owner side (entity_id)" do
      expect(delete_rule_for("entity_id")).to eq("c") # confdeltype 'c' = CASCADE
    end

    it "nullifies on the target side (author_id)" do
      expect(delete_rule_for("author_id")).to eq("n") # confdeltype 'n' = SET NULL
    end

    it "enforces the unique (entity_id, slot) index (one relationship per owner)" do
      indexes = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'post_authors'"
      )
      expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
    end

    # The behaviour the whole feature turns on, proven end to end: destroying the
    # target nullifies the link and leaves the row (and thus the owner) standing.
    it "nulls the target column when the target entity is deleted" do
      make_entity = lambda do
        connection.select_value("INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id")
      end
      owner = make_entity.call
      target = make_entity.call
      connection.execute(
        "INSERT INTO post_authors (entity_id, author_id, created_at, updated_at) " \
        "VALUES ('#{owner}', '#{target}', now(), now())"
      )

      connection.execute("DELETE FROM entities WHERE id = '#{target}'")

      aggregate_failures do
        expect(connection.select_value("SELECT count(*) FROM post_authors").to_i).to eq(1)
        expect(connection.select_value("SELECT author_id FROM post_authors")).to be_nil
      end
    end
  end

  # RFC-0014 / ADR-0015: `rails g ecs_rails:upgrade` brings a pre-slot component
  # table forward — adds the column, swaps the unique index — and does nothing
  # for a table that already has it. Executed against the real catalog: the
  # pre-slot table is built by hand, the way a 0.2.x app left it.
  describe "the upgrade migration" do
    def indexes_of(table)
      connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = '#{table}'"
      )
    end

    before do
      # A 0.2.x-shaped component table: no slot, entity_id-only unique index.
      connection.execute(<<~SQL)
        CREATE TABLE names (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          first character varying,
          created_at timestamp NOT NULL, updated_at timestamp NOT NULL
        );
        CREATE UNIQUE INDEX index_names_on_entity_id ON names (entity_id);
      SQL
      connection.schema_cache.clear!
    end

    it "adds slot and the composite index to the table that lacks them" do
      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_add_slots", "EcsRailsAddSlots")

      slot = columns_of("names").find { |c| c["column_name"] == "slot" }

      aggregate_failures do
        expect(slot).not_to be_nil
        expect(slot["is_nullable"]).to eq("NO")
        expect(indexes_of("names")).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
        expect(indexes_of("names")).not_to include(match(/\(entity_id\)$/))
      end
    end

    it "leaves a table that already has slot alone" do
      generate(EcsRails::Generators::UpgradeGenerator, [])
      contents = migration("ecs_rails_add_slots")

      aggregate_failures do
        expect(contents).to include("add_column :names, :slot")
        expect(contents).not_to include("add_column :emails")
        expect(contents).not_to include(":entities")
      end
    end

    it "keeps existing rows, all in the default slot" do
      entity_id = connection.select_value(
        "INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id"
      )
      connection.execute("INSERT INTO names (entity_id, first, created_at, updated_at) VALUES ('#{entity_id}', 'Ada', now(), now())")

      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_add_slots", "EcsRailsAddSlots")

      expect(connection.select_all("SELECT first, slot FROM names").to_a).to eq([{ "first" => "Ada", "slot" => "" }])
    end

    it "writes nothing when every component table is already current" do
      connection.execute("DROP TABLE names")
      connection.schema_cache.clear!

      generate(EcsRails::Generators::UpgradeGenerator, [])

      expect(migration_paths("ecs_rails_add_slots")).to be_empty
    end
  end
end
