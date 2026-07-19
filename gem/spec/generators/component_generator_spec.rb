# frozen_string_literal: true

require_relative "generator_helper"

# RFC-0008: `rails g ecs_rails:component NAME [attributes]`.
#
# The invariants under test are architecture.md §2 and ADR-0005: every component
# table gets a non-null entity_id with a UNIQUE index and an ON DELETE CASCADE
# FK, and every attribute gets an explicit default (RFC-0006).
RSpec.describe EcsRails::Generators::ComponentGenerator, type: :generator do
  describe "the migration" do
    subject(:contents) { migration("create_emails") }

    before { run_generator %w[Email address:string verified:boolean] }

    it "gives the table a UUID primary key defaulting to gen_random_uuid()" do
      expect(contents).to match(
        /create_table :emails, id: :uuid, default: -> \{ "gen_random_uuid\(\)" \}/
      )
    end

    it "declares entity_id as a non-null uuid" do
      expect(contents).to match(/t\.uuid :entity_id, null: false/)
    end

    # ADR-0005 — non-negotiable.
    it "makes the entity_id index unique" do
      expect(contents).to match(/add_index .*:emails, :entity_id, unique: true/)
    end

    it "cascades on delete" do
      expect(contents).to match(/on_delete: :cascade/)
    end

    it "points the foreign key at entities" do
      expect(contents).to match(
        /add_foreign_key :emails, :entities, column: :entity_id, on_delete: :cascade/
      )
    end

    it "gives every attribute an explicit default" do
      expect(contents).to match(/t\.string :address, default: nil/)
    end

    it "defaults booleans to false and makes them non-null" do
      expect(contents).to match(/t\.boolean :verified, default: false, null: false/)
    end

    it "adds timestamps" do
      expect(contents).to match(/t\.timestamps/)
    end
  end

  # RFC-0006 is the reason this rule exists: a virtual component reports its
  # defaults, so a column with no explicit default is a silent nil.
  describe "the explicit-default policy" do
    it "writes default: nil for every non-boolean type" do
      run_generator %w[Thing a:string b:integer c:text d:datetime e:decimal f:uuid]

      contents = migration("create_things")

      aggregate_failures do
        expect(contents).to match(/t\.string :a, default: nil/)
        expect(contents).to match(/t\.integer :b, default: nil/)
        expect(contents).to match(/t\.text :c, default: nil/)
        expect(contents).to match(/t\.datetime :d, default: nil/)
        expect(contents).to match(/t\.decimal :e, default: nil/)
        expect(contents).to match(/t\.uuid :f, default: nil/)
      end
    end

    it "leaves no attribute column without a default" do
      run_generator %w[Thing a:string b:integer c:boolean]

      attribute_lines = migration("create_things").lines.grep(/^\s+t\.(?!timestamps|uuid :entity_id)/)

      expect(attribute_lines).to all(match(/default:/))
    end
  end

  describe "with no attributes" do
    before { run_generator %w[Email] }

    it "still emits a migration" do
      expect(migration_paths("create_emails").size).to eq(1)
    end

    it "still enforces the entity_id invariants" do
      aggregate_failures do
        expect(migration("create_emails")).to match(/t\.uuid :entity_id, null: false/)
        expect(migration("create_emails")).to match(/add_index :emails, :entity_id, unique: true/)
        expect(migration("create_emails")).to match(/on_delete: :cascade/)
      end
    end

    it "still creates the model" do
      expect(file("app/entities/components/email.rb")).to match(/class Email < ApplicationComponent/)
    end
  end

  # ADR-0010: the model lands under app/entities/components, not app/models.
  describe "the model" do
    before { run_generator %w[Email address:string] }

    it "is created under app/entities/components" do
      expect(file("app/entities/components/email.rb")).to match(/class Email < ApplicationComponent/)
    end
  end

  # ADR-0010: the spec mirrors the layout under spec/entities/components and must
  # declare type: :model explicitly, since rspec-rails only infers that from
  # spec/models/.
  describe "the spec file" do
    before { run_generator %w[Email address:string] }

    it "is created under spec/entities/components" do
      expect(file?("spec/entities/components/email_spec.rb")).to be(true)
    end

    it "describes the component" do
      expect(file("spec/entities/components/email_spec.rb")).to match(/RSpec\.describe Email/)
    end

    it "declares type: :model explicitly" do
      expect(file("spec/entities/components/email_spec.rb"))
        .to match(/RSpec\.describe Email, type: :model/)
    end
  end

  # ADR-0010's escape hatch: entities_path = "app/models" relocates generated
  # files. Components then live in app/models/components (components_path is
  # always entities_path/components).
  describe "with entities_path overridden to app/models" do
    before do
      EcsRails.configure { |c| c.entities_path = "app/models" }
      run_generator %w[Email address:string]
    end

    it "writes the model under app/models/components" do
      expect(file("app/models/components/email.rb"))
        .to match(/class Email < ApplicationComponent/)
    end
  end

  # Two generators invoked in the same second must not collide. Rails'
  # next_migration_number bumps past the highest existing version rather than
  # re-deriving the timestamp.
  describe "migration numbering" do
    it "does not collide when run twice in the same second" do
      run_generator %w[Email address:string]
      run_generator %w[Name first:string]

      versions = Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
                    .map { |path| File.basename(path).split("_").first }

      aggregate_failures do
        expect(versions.size).to eq(2)
        expect(versions.uniq.size).to eq(2)
      end
    end
  end
end
