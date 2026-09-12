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

  # Runs a specific generator class, since this file exercises several. `args`
  # is the whole command line, switches included — see GeneratorHelper.
  def generate(generator_class, args)
    positional, switches = Thor::Options.split(args)
    generator = generator_class.new(positional, switches, destination_root: destination_root)
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
    generate(EcsRails::Generators::ComponentGenerator, %w[Gadget address:string verified:boolean])

    run_migration("ecs_rails_install", "EcsRailsInstall")
    run_migration("create_gadgets", "CreateGadgets")
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
      entity_id = columns_of("gadgets").find { |c| c["column_name"] == "entity_id" }

      aggregate_failures do
        expect(entity_id["data_type"]).to eq("uuid")
        expect(entity_id["is_nullable"]).to eq("NO")
      end
    end

    it "applies the explicit defaults" do
      cols = columns_of("gadgets")
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
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'gadgets'"
      )
      expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
    end

    it "gives slot a non-null empty-string default" do
      slot = columns_of("gadgets").find { |c| c["column_name"] == "slot" }

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
        WHERE n.nspname = '#{scratch_schema}' AND t.relname = 'gadgets' AND c.contype = 'f'
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
      connection.execute("INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      expect do
        violating do
          connection.execute("INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # RFC-0014 / ADR-0015: the same component in another slot is a second row.
    it "accepts a second row for the same entity in a different slot" do
      entity_id = create_entity
      connection.execute("INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")
      connection.execute(
        "INSERT INTO gadgets (entity_id, slot, created_at, updated_at) VALUES ('#{entity_id}', 'work', now(), now())"
      )

      expect(connection.select_value("SELECT count(*) FROM gadgets").to_i).to eq(2)
    end

    it "rejects a component row with no entity" do
      expect do
        violating do
          connection.execute("INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES (NULL, now(), now())")
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "rejects a component row pointing at a non-existent entity" do
      expect do
        violating do
          connection.execute(
            "INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES ('#{SecureRandom.uuid}', now(), now())"
          )
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "cascades a deleted entity to its component rows" do
      entity_id = create_entity
      connection.execute("INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      connection.execute("DELETE FROM entities WHERE id = '#{entity_id}'")

      expect(connection.select_value("SELECT count(*) FROM gadgets").to_i).to eq(0)
    end

    it "applies the boolean default on insert" do
      entity_id = create_entity
      connection.execute("INSERT INTO gadgets (entity_id, created_at, updated_at) VALUES ('#{entity_id}', now(), now())")

      expect(connection.select_value("SELECT verified FROM gadgets")).to be(false)
    end
  end

  # ADR-0017: the shared relationships table, created by install and executed
  # against the real catalog. The point is the asymmetric FK delete rules —
  # entity_id CASCADE, target_id NULLIFY — and the partial unique index that
  # makes `unique: true` a database guarantee.
  describe "the relationships table" do
    def delete_rule_for(column)
      connection.select_value(<<~SQL)
        SELECT c.confdeltype
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE n.nspname = '#{scratch_schema}' AND t.relname = 'relationships'
          AND c.contype = 'f' AND a.attname = '#{column}'
      SQL
    end

    def indexes
      connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'relationships'"
      )
    end

    def make_entity(model = "users")
      connection.select_value("INSERT INTO entities (model, created_at) VALUES ('#{model}', now()) RETURNING id")
    end

    def link(owner, target, slot: "order", owner_model: "invoices", exclusive: false)
      connection.execute(
        "INSERT INTO relationships (entity_id, slot, target_id, owner_model, exclusive, created_at, updated_at) " \
        "VALUES ('#{owner}', '#{slot}', '#{target}', '#{owner_model}', #{exclusive}, now(), now())"
      )
    end

    it "is created by install" do
      names = columns_of("relationships").map { |c| c["column_name"] }
      expect(names).to contain_exactly(
        "id", "entity_id", "slot", "target_id", "owner_model", "exclusive", "created_at", "updated_at"
      )
    end

    it "cascades on the owner side (entity_id)" do
      expect(delete_rule_for("entity_id")).to eq("c") # confdeltype 'c' = CASCADE
    end

    it "nullifies on the target side (target_id)" do
      expect(delete_rule_for("target_id")).to eq("n") # confdeltype 'n' = SET NULL
    end

    it "enforces one target per (owner, slot)" do
      expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
    end

    it "indexes (target_id, slot) for inverse lookups" do
      expect(indexes).to include(match(/CREATE INDEX .*\(target_id, slot\)/))
    end

    it "carries the partial unique index for exclusive rows" do
      expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(target_id, slot, owner_model\) WHERE exclusive/))
    end

    # The behaviour the whole feature turns on, proven end to end: destroying the
    # target nullifies the link and leaves the row (and thus the owner) standing.
    it "nulls target_id when the target entity is deleted" do
      owner = make_entity("posts")
      target = make_entity
      link(owner, target, slot: "author", owner_model: "posts")

      connection.execute("DELETE FROM entities WHERE id = '#{target}'")

      aggregate_failures do
        expect(connection.select_value("SELECT count(*) FROM relationships").to_i).to eq(1)
        expect(connection.select_value("SELECT target_id FROM relationships")).to be_nil
      end
    end

    it "rejects a second exclusive owner of the same type for one target" do
      target = make_entity("orders")
      link(make_entity("invoices"), target, exclusive: true)

      expect { violating { link(make_entity("invoices"), target, exclusive: true) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows a second owner when the rows are not exclusive" do
      target = make_entity("orders")
      link(make_entity("invoices"), target)
      link(make_entity("invoices"), target)

      expect(connection.select_value("SELECT count(*) FROM relationships").to_i).to eq(2)
    end

    it "scopes exclusivity to the owner type" do
      # An Invoice and an OrderItem may both point exclusively at one Order.
      target = make_entity("orders")
      link(make_entity("invoices"), target, exclusive: true)
      link(make_entity("order_items"), target, owner_model: "order_items", exclusive: true)

      expect(connection.select_value("SELECT count(*) FROM relationships").to_i).to eq(2)
    end
  end

  # ADR-0018 / RFC-0017: install creates every core catalogue table, each with
  # the §2 invariants, and the tables ARE the gem's declarations.
  describe "the catalogue tables" do
    it "are all created, with the unique (entity_id, slot) index and a cascading FK" do
      scratch_tables = connection.select_values(
        "SELECT tablename FROM pg_tables WHERE schemaname = '#{scratch_schema}'"
      )
      core = EcsRails::Catalogue.in_sets(:core)

      aggregate_failures do
        core.each do |component|
          expect(scratch_tables).to include(component.table)
          indexes = connection.select_values(
            "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = '#{component.table}'"
          )
          expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/)), component.table
        end
        expect(scratch_tables).not_to include("monies")
      end
    end

    it "gives Identifier its per-slot uniqueness and Tags its GIN index" do
      identifiers = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'identifiers'"
      )
      tags = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'tags'"
      )

      aggregate_failures do
        expect(identifiers).to include(match(/CREATE UNIQUE INDEX .*\(slot, value\)/))
        expect(tags).to include(match(/USING gin \(names\)/))
      end
    end
  end

  # RFC-0017: the upgrade's catalogue job — a missing table (a set added later,
  # or a newer gem's component) is created; a table that predates a column gets
  # it. Nothing is dropped.
  describe "the catalogue upgrade" do
    before { connection.execute("SET LOCAL search_path TO #{scratch_schema}") }

    it "creates the tables of a set added later, and their classes" do
      generate(EcsRails::Generators::UpgradeGenerator, %w[--sets core commerce])
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")

      aggregate_failures do
        expect(connection.tables).to include("monies")
        expect(file("app/entities/components/money.rb")).to match(/include EcsRails::Catalogue::Money/)
        expect(migration("ecs_rails_catalogue")).not_to include("create_table :texts") # already there
      end
    end

    it "adds a column a table predates, without touching the rest" do
      connection.execute("ALTER TABLE addresses DROP COLUMN line2")
      connection.schema_cache.clear!

      generate(EcsRails::Generators::UpgradeGenerator, [])
      contents = migration("ecs_rails_catalogue")
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")

      aggregate_failures do
        expect(contents.lines.grep(/add_column|create_table/).map(&:strip))
          .to eq(["add_column :addresses, :line2, :string, default: nil"])
        expect(columns_of("addresses").map { |c| c["column_name"] }).to include("line2")
      end
    end

    it "leaves a bespoke table that shares a catalogue name alone when no class claims it" do
      # `monies` exists but is the app's own (no class including Catalogue::Money)
      # and commerce is not selected: not the upgrade's business.
      connection.execute("CREATE TABLE monies (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), entity_id uuid NOT NULL, slot character varying NOT NULL DEFAULT '', total integer, created_at timestamp NOT NULL, updated_at timestamp NOT NULL)")
      connection.schema_cache.clear!

      generate(EcsRails::Generators::UpgradeGenerator, [])

      expect(migration_paths("ecs_rails_catalogue")).to be_empty
    end

    it "does not mistake a nonunique lookalike for identifier uniqueness" do
      connection.remove_index(:identifiers, column: %i[slot value])
      connection.add_index(:identifiers, %i[slot value])

      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/identifiers.*index.*unique/m)
      expect(migration_paths("ecs_rails_catalogue")).to be_empty
    end

    it "restores a missing owner foreign key and preserves existing rows" do
      entity = connection.select_value("INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id")
      connection.execute("INSERT INTO addresses (entity_id, line1, created_at, updated_at) VALUES ('#{entity}', 'Keep me', now(), now())")
      connection.remove_foreign_key(:addresses, column: :entity_id)

      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")

      foreign_key = connection.foreign_keys(:addresses).find { |key| key.column == "entity_id" }
      expect(foreign_key.on_delete).to eq :cascade
      expect(connection.select_value("SELECT line1 FROM addresses")).to eq "Keep me"
    end

    it "diagnoses an altered column default before writing upgrade files" do
      connection.change_column_default(:counters, :count, 7)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/counters.count.*default.*7.*0/m)
      expect(migration_paths("ecs_rails_catalogue")).to be_empty
    end

    {
      "nullability" => [->(db) { db.change_column_null(:counters, :count, true) }, /counters.count null.*true.*false/],
      "integer width" => [->(db) { db.change_column(:counters, :count, :bigint) }, /counters.count limit.*8.*4/],
      "column type" => [->(db) { db.change_column(:addresses, :line1, :text) }, /addresses.line1 type.*text.*string/],
      "string limit" => [->(db) { db.change_column(:addresses, :country, :string, limit: 3) }, /addresses.country limit.*3.*2/],
      "decimal precision" => [->(db) { db.change_column(:geolocations, :lat, :decimal, precision: 11, scale: 7) }, /geolocations.lat precision.*11.*10/],
      "decimal scale" => [->(db) { db.change_column(:geolocations, :lat, :decimal, precision: 10, scale: 6) }, /geolocations.lat scale.*6.*7/],
      "timestamp precision" => [->(db) { db.change_column(:addresses, :created_at, :datetime, precision: 3) }, /addresses.created_at precision.*3.*6/],
      "JSON default" => [->(db) { db.change_column_default(:states, :transitions, {}) }, /states.transitions default.*\{\}.*\[\]/],
      "array default" => [->(db) { db.change_column_default(:tags, :names, ["changed"]) }, /tags.names default.*changed.*\[\]/],
      "UUID generation" => [->(db) { db.change_column_default(:counters, :id, "00000000-0000-0000-0000-000000000001") }, /counters.id default.*gen_random_uuid/]
    }.each do |property, (alter, message)|
      it "diagnoses changed #{property} without altering the column" do
        alter.call(connection)
        tables = %w[addresses counters geolocations states tags]
        before = tables.to_h { |table| [table, connection.columns(table)] }
        expect { generate(EcsRails::Generators::UpgradeGenerator, []) }.to raise_error(message)
        expect(tables.to_h { |table| [table, connection.columns(table)] }).to eq before
        expect(migration_paths("ecs_rails_catalogue")).to be_empty
      end
    end

    it "diagnoses an absent non-null column that needs a backfill" do
      connection.remove_column(:relationships, :owner_model)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/relationships.owner_model is missing.*backfill/)
    end

    it "diagnoses a changed partial uniqueness predicate" do
      connection.remove_index(:relationships, name: "index_relationships_exclusive")
      connection.add_index(:relationships, %i[target_id slot owner_model], unique: true,
                           where: "NOT exclusive", name: "index_relationships_exclusive")
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/relationships.index.*NOT exclusive.*exclusive/m)
    end

    it "accepts renamed matching indexes and equivalent Boolean predicates" do
      connection.remove_index(:relationships, name: "index_relationships_exclusive")
      connection.add_index(:relationships, %i[target_id slot owner_model], unique: true,
                           where: "exclusive IS TRUE", name: "custom_exclusive_index")
      generate(EcsRails::Generators::UpgradeGenerator, [])
      expect(migration_paths("ecs_rails_catalogue")).to be_empty
    end

    it "diagnoses a changed index access method" do
      connection.remove_index(:tags, column: :names)
      connection.add_index(:tags, :names, using: :btree)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/tags.index.*btree.*gin/m)
    end

    it "diagnoses a nonunique singleton index" do
      connection.remove_index(:addresses, column: %i[entity_id slot])
      connection.add_index(:addresses, %i[entity_id slot])
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/addresses.index.*unique.*false.*true/m)
    end

    it "diagnoses a foreign key with the wrong deletion behavior" do
      connection.remove_foreign_key(:relationships, column: :target_id)
      connection.add_foreign_key(:relationships, :entities, column: :target_id, on_delete: :cascade)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/relationships.foreign key target_id.*cascade.*nullify/m)
    end

    it "diagnoses an unvalidated foreign key" do
      connection.remove_foreign_key(:addresses, column: :entity_id)
      connection.add_foreign_key(:addresses, :entities, column: :entity_id, on_delete: :cascade, validate: false)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/addresses.foreign key entity_id.*validate.*false.*true/m)
    end

    it "diagnoses a foreign key pointing to a different table" do
      connection.create_table(:other_entities, id: :uuid)
      connection.remove_foreign_key(:addresses, column: :entity_id)
      connection.add_foreign_key(:addresses, :other_entities, column: :entity_id, on_delete: :cascade)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/addresses.foreign key entity_id.*other_entities.*entities/m)
    end

    it "adds missing constraints, retains legacy relationships and is current on the next generation" do
      owner = connection.select_value("INSERT INTO entities (model, created_at) VALUES ('posts', now()) RETURNING id")
      target = connection.select_value("INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id")
      connection.execute("INSERT INTO relationships (entity_id, slot, target_id, owner_model, exclusive, created_at, updated_at) VALUES ('#{owner}', 'author', '#{target}', 'posts', true, now(), now())")
      connection.remove_foreign_key(:relationships, column: :target_id)
      connection.remove_index(:relationships, name: "index_relationships_exclusive")
      connection.remove_index(:relationships, column: %i[entity_id slot])

      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")
      expect(connection.select_value("SELECT target_id FROM relationships")).to eq target
      indexes = connection.indexes(:relationships)
      expect(indexes.find { |index| index.columns == %w[entity_id slot] }.unique).to eq true
      expect(indexes.find { |index| index.name == "index_relationships_exclusive" }.where).to eq "exclusive"
      connection.execute("DELETE FROM entities WHERE id = '#{target}'")
      expect(connection.select_value("SELECT target_id FROM relationships")).to be_nil
      expect(connection.select_value("SELECT entity_id FROM relationships")).to eq owner

      files = Dir.glob(File.join(destination_root, "db/migrate/*"))
      generate(EcsRails::Generators::UpgradeGenerator, [])
      expect(Dir.glob(File.join(destination_root, "db/migrate/*"))).to eq files
    end

    it "fails a new unique constraint on duplicate legacy data without deleting it" do
      connection.remove_index(:identifiers, column: %i[slot value])
      2.times do
        owner = connection.select_value("INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id")
        connection.execute("INSERT INTO identifiers (entity_id, slot, value, created_at, updated_at) VALUES ('#{owner}', 'legacy', 'duplicate', now(), now())")
      end
      generate(EcsRails::Generators::UpgradeGenerator, [])
      expect { violating { run_migration("ecs_rails_catalogue", "EcsRailsCatalogue") } }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect(connection.select_values("SELECT value FROM identifiers")).to eq %w[duplicate duplicate]
    end

    it "accounts for the pre-slot migration on an existing catalogue table" do
      connection.remove_column(:addresses, :slot)
      connection.add_index(:addresses, :entity_id, unique: true)
      owner = connection.select_value("INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id")
      connection.execute("INSERT INTO addresses (entity_id, line1, created_at, updated_at) VALUES ('#{owner}', 'Legacy', now(), now())")
      generate(EcsRails::Generators::UpgradeGenerator, [])
      expect(migration_paths("ecs_rails_catalogue")).to be_empty
      run_migration("ecs_rails_add_slots", "EcsRailsAddSlots")
      expect(connection.select_all("SELECT line1, slot FROM addresses").to_a).to eq [{ "line1" => "Legacy", "slot" => "" }]
      expect(EcsRails::Catalogue::Address.schema.to_ruby_diff(table_name: :addresses, connection: connection)).to eq ""
    end

    it "stops before a pending slot migration or class file is written on mismatch" do
      connection.remove_column(:addresses, :slot)
      connection.add_index(:addresses, :entity_id, unique: true)
      connection.change_column_default(:counters, :count, 7)
      File.delete(File.join(destination_root, "app/entities/components/counter.rb"))
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }.to raise_error(/counters.count default/)
      expect(migration_paths("ecs_rails_add_slots")).to be_empty
      expect(file?("app/entities/components/counter.rb")).to eq false
    end

    it "does not mistake a catalogue table missing its attributes for a legacy marker" do
      EcsRails::Catalogue::Address.schema.columns.each { |column| connection.remove_column(:addresses, column.name) }
      owner = connection.select_value("INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id")
      connection.execute("INSERT INTO addresses (entity_id, created_at, updated_at) VALUES ('#{owner}', now(), now())")
      generate(EcsRails::Generators::UpgradeGenerator, [])
      expect(migration_paths("ecs_rails_shared_markers")).to be_empty
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")
      expect(connection.select_value("SELECT entity_id FROM addresses")).to eq owner
      expect(EcsRails::Catalogue::Address.schema.to_ruby_diff(table_name: :addresses, connection: connection)).to eq ""
    end

    it "diagnoses an array column changed to a scalar" do
      connection.remove_index(:tags, column: :names)
      connection.change_column_default(:tags, :names, nil)
      connection.change_column(:tags, :names, :string, array: false, using: "names::text")
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/tags.names array.*false.*true/)
    end

    it "diagnoses a missing UUID primary key constraint" do
      connection.execute("ALTER TABLE addresses DROP CONSTRAINT addresses_pkey")
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/addresses.primary key.*nil.*id/)
    end

    it "diagnoses a pre-slot table without the required legacy unique index" do
      connection.remove_column(:addresses, :slot)
      connection.add_index(:addresses, :entity_id)
      expect { generate(EcsRails::Generators::UpgradeGenerator, []) }
        .to raise_error(/addresses pre-slot upgrade needs an unconditional unique index/)
      expect(migration_paths("ecs_rails_add_slots")).to be_empty
    end

    it "never moves the shared markers table when its class file is missing" do
      File.delete(File.join(destination_root, "app/entities/components/marker.rb"))
      generate(EcsRails::Generators::UpgradeGenerator, %w[--sets commerce])
      expect(migration_paths("ecs_rails_shared_markers")).to be_empty
    end

    it "does not overwrite an application's edited class" do
      File.write(File.join(destination_root, "app/entities/components/text.rb"), "# edited\n")

      generate(EcsRails::Generators::UpgradeGenerator, [])

      expect(file("app/entities/components/text.rb")).to eq("# edited\n")
    end
  end

  # ADR-0018 §4: the shared markers table, created by install.
  describe "the markers table" do
    it "is created with the unique (entity_id, slot) index and a cascading FK" do
      names = columns_of("markers").map { |c| c["column_name"] }
      indexes = connection.select_values(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = '#{scratch_schema}' AND tablename = 'markers'"
      )

      aggregate_failures do
        expect(names).to contain_exactly("id", "entity_id", "slot", "created_at", "updated_at")
        expect(indexes).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
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
      # Scratch schema only — see the shared-relationships describe below.
      connection.execute("SET LOCAL search_path TO #{scratch_schema}")
      # A 0.2.x-shaped component table: no slot, entity_id-only unique index.
      connection.execute(<<~SQL)
        CREATE TABLE nicknames (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          first character varying,
          created_at timestamp NOT NULL, updated_at timestamp NOT NULL
        );
        CREATE UNIQUE INDEX index_nicknames_on_entity_id ON nicknames (entity_id);
      SQL
      connection.schema_cache.clear!
    end

    it "adds slot and the composite index to the table that lacks them" do
      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_add_slots", "EcsRailsAddSlots")

      slot = columns_of("nicknames").find { |c| c["column_name"] == "slot" }

      aggregate_failures do
        expect(slot).not_to be_nil
        expect(slot["is_nullable"]).to eq("NO")
        expect(indexes_of("nicknames")).to include(match(/CREATE UNIQUE INDEX .*\(entity_id, slot\)/))
        expect(indexes_of("nicknames")).not_to include(match(/\(entity_id\)$/))
      end
    end

    it "leaves a table that already has slot alone" do
      generate(EcsRails::Generators::UpgradeGenerator, [])
      contents = migration("ecs_rails_add_slots")

      aggregate_failures do
        expect(contents).to include("add_column :nicknames, :slot")
        expect(contents).not_to include("add_column :gadgets")
        expect(contents).not_to include(":entities")
      end
    end

    it "keeps existing rows, all in the default slot" do
      entity_id = connection.select_value(
        "INSERT INTO entities (model, created_at) VALUES ('users', now()) RETURNING id"
      )
      connection.execute("INSERT INTO nicknames (entity_id, first, created_at, updated_at) VALUES ('#{entity_id}', 'Ada', now(), now())")

      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_add_slots", "EcsRailsAddSlots")

      expect(connection.select_all("SELECT first, slot FROM nicknames").to_a).to eq([{ "first" => "Ada", "slot" => "" }])
    end

    it "writes nothing when every component table is already current" do
      connection.execute("DROP TABLE nicknames")
      connection.schema_cache.clear!

      generate(EcsRails::Generators::UpgradeGenerator, [])

      aggregate_failures do
        expect(migration_paths("ecs_rails_catalogue")).to be_empty
        expect(migration_paths("ecs_rails_add_slots")).to be_empty
        expect(migration_paths("ecs_rails_shared_relationships")).to be_empty
        expect(migration_paths("ecs_rails_shared_markers")).to be_empty
      end
    end
  end

  # ADR-0018 §4: the upgrade's third job. A pre-0.3 application has one empty
  # table per marker (`moderators`); the generated migration copies each into
  # `markers` under the table's singular name and drops it.
  describe "the shared-markers upgrade" do
    def make_entity(model)
      connection.select_value("INSERT INTO entities (model, created_at) VALUES ('#{model}', now()) RETURNING id")
    end

    before do
      connection.execute("SET LOCAL search_path TO #{scratch_schema}")
      connection.execute("DROP TABLE markers") # a 0.2.x app has none
      connection.execute(<<~SQL)
        CREATE TABLE moderators (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          created_at timestamp NOT NULL, updated_at timestamp NOT NULL
        );
        CREATE UNIQUE INDEX index_moderators_on_entity_id ON moderators (entity_id);
      SQL
      connection.schema_cache.clear!
    end

    it "recognises the marker table and skips it in the slots migration" do
      generate(EcsRails::Generators::UpgradeGenerator, [])
      contents = migration("ecs_rails_shared_markers")

      aggregate_failures do
        expect(contents).to include("FROM moderators", "drop_table :moderators")
        expect(contents).not_to include("create_table")
        expect(migration("ecs_rails_catalogue")).to include("create_table :markers")
        expect(migration_paths("ecs_rails_add_slots")).to be_empty
      end
    end

    it "moves the rows under the singular name and drops the table" do
      user = make_entity("users")
      connection.execute("INSERT INTO moderators (entity_id, created_at, updated_at) VALUES ('#{user}', now(), now())")

      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")
      run_migration("ecs_rails_shared_markers", "EcsRailsSharedMarkers")

      aggregate_failures do
        expect(connection.select_all("SELECT entity_id, slot FROM markers").to_a)
          .to eq([{ "entity_id" => user, "slot" => "moderator" }])
        expect(connection.tables).not_to include("moderators")
      end
    end

    it "leaves a component with attributes alone" do
      generate(EcsRails::Generators::UpgradeGenerator, [])

      expect(migration("ecs_rails_shared_markers")).not_to include("gadgets")
    end
  end

  # ADR-0017: the upgrade's second job. A pre-0.3 application has one backing
  # table per relationship (`post_authors`, with `author_id`); the generated
  # migration copies each into `relationships` under the relationship's name
  # and drops it. Built by hand here in the shape ADR-0013's generator left it.
  describe "the shared-relationships upgrade" do
    def make_entity(model)
      connection.select_value("INSERT INTO entities (model, created_at) VALUES ('#{model}', now()) RETURNING id")
    end

    before do
      # Scratch schema ONLY: the generator inspects `connection.tables`, and with
      # public still on the search_path the real test schema's `relationships`
      # would read as already present. gen_random_uuid() is pg_catalog's on
      # PostgreSQL 13+, so nothing here needs public.
      connection.execute("SET LOCAL search_path TO #{scratch_schema}")
      connection.execute("DROP TABLE relationships") # a 0.2.x app has none
      connection.execute(<<~SQL)
        CREATE TABLE post_authors (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          author_id uuid REFERENCES entities(id) ON DELETE SET NULL,
          created_at timestamp NOT NULL, updated_at timestamp NOT NULL
        );
        CREATE UNIQUE INDEX index_post_authors_on_entity_id ON post_authors (entity_id);
        CREATE TABLE membership_users (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          user_id uuid REFERENCES entities(id) ON DELETE SET NULL,
          created_at timestamp NOT NULL, updated_at timestamp NOT NULL
        );
        CREATE UNIQUE INDEX index_membership_users_on_entity_id ON membership_users (entity_id);
      SQL
      connection.schema_cache.clear!
    end

    it "recognises the backing tables and skips them in the slots migration" do
      generate(EcsRails::Generators::UpgradeGenerator, [])
      contents = migration("ecs_rails_shared_relationships")

      aggregate_failures do
        expect(contents).to include("FROM post_authors", "drop_table :post_authors")
        expect(contents).to include("FROM membership_users", "drop_table :membership_users")
        expect(contents).not_to include("create_table") # the catalogue migration creates relationships
        expect(migration("ecs_rails_catalogue")).to include("create_table :relationships")
        expect(migration_paths("ecs_rails_add_slots")).to be_empty # gadgets already has slot; backings skipped
      end
    end

    it "moves the rows under the relationship name and owner model, then drops the tables" do
      post = make_entity("posts")
      user = make_entity("users")
      membership = make_entity("memberships")
      connection.execute("INSERT INTO post_authors (entity_id, author_id, created_at, updated_at) VALUES ('#{post}', '#{user}', now(), now())")
      connection.execute("INSERT INTO membership_users (entity_id, user_id, created_at, updated_at) VALUES ('#{membership}', '#{user}', now(), now())")

      generate(EcsRails::Generators::UpgradeGenerator, [])
      run_migration("ecs_rails_catalogue", "EcsRailsCatalogue")
      run_migration("ecs_rails_shared_relationships", "EcsRailsSharedRelationships")

      rows = connection.select_all(
        "SELECT entity_id, slot, target_id, owner_model, exclusive FROM relationships ORDER BY slot"
      ).to_a
      aggregate_failures do
        expect(rows).to eq([
          { "entity_id" => post, "slot" => "author", "target_id" => user, "owner_model" => "posts", "exclusive" => false },
          { "entity_id" => membership, "slot" => "user", "target_id" => user, "owner_model" => "memberships", "exclusive" => false }
        ])
        expect(connection.tables).not_to include("post_authors", "membership_users")
      end
    end

    it "leaves a bespoke single-foreign-key component alone" do
      # `sponsors` (entity_id + sponsor_id) has the shape but not the name.
      connection.execute(<<~SQL)
        CREATE TABLE sponsors (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
          slot character varying NOT NULL DEFAULT '',
          sponsor_id uuid,
          created_at timestamp NOT NULL, updated_at timestamp NOT NULL
        );
      SQL
      connection.schema_cache.clear!

      generate(EcsRails::Generators::UpgradeGenerator, [])

      expect(migration("ecs_rails_shared_relationships")).not_to include("sponsors")
    end

    it "writes no data move when there is nothing to move, and creates the table in the catalogue migration" do
      connection.execute("DROP TABLE post_authors; DROP TABLE membership_users")
      connection.schema_cache.clear!

      generate(EcsRails::Generators::UpgradeGenerator, [])

      aggregate_failures do
        expect(migration_paths("ecs_rails_shared_relationships")).to be_empty
        expect(migration("ecs_rails_catalogue")).to include("create_table :relationships")
      end
    end
  end
end
