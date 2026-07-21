# frozen_string_literal: true

require_relative "generator_helper"

# RFC-0012 / ADR-0013: `rails g ecs_rails:relationship OWNER name:Target`.
#
#   rails g ecs_rails:relationship Post author:User
#
# The invariants under test: the owner-scoped table name (`post_authors`), the
# asymmetric foreign keys (entity_id CASCADE, author_id NULLIFY), and the fact
# that NO model file is written — `relates_to` defines the backing component.
RSpec.describe EcsRails::Generators::RelationshipGenerator, type: :generator do
  describe "the migration" do
    subject(:contents) { migration("create_post_authors") }

    before { run_generator %w[Post author:User] }

    it "names the table after the owner and relation, pluralised" do
      expect(contents).to match(
        /create_table :post_authors, id: :uuid, default: -> \{ "gen_random_uuid\(\)" \}/
      )
    end

    it "declares entity_id as a non-null uuid" do
      expect(contents).to match(/t\.uuid :entity_id, null: false/)
    end

    it "declares the target foreign-key column, nullable" do
      expect(contents).to match(/t\.uuid :author_id, default: nil/)
    end

    # ADR-0005 — one relationship row per owner.
    it "makes the entity_id index unique" do
      expect(contents).to match(/add_index :post_authors, :entity_id, unique: true/)
    end

    it "cascades on the owner side (entity_id)" do
      expect(contents).to match(
        /add_foreign_key :post_authors, :entities, column: :entity_id, on_delete: :cascade/
      )
    end

    # THE load-bearing asymmetry (ADR-0013): the target FK nullifies, not cascades.
    it "nullifies on the target side (author_id)" do
      expect(contents).to match(
        /add_foreign_key :post_authors, :entities, column: :author_id, on_delete: :nullify/
      )
    end

    it "indexes the target foreign key" do
      expect(contents).to match(/add_index :post_authors, :author_id/)
    end

    it "adds timestamps" do
      expect(contents).to match(/t\.timestamps/)
    end
  end

  # RFC-0012: no component file — the DSL defines the backing component.
  describe "no model file" do
    before { run_generator %w[Post author:User] }

    it "writes no relationship component under app/entities/components" do
      expect(file?("app/entities/components/author_relationship.rb")).to be(false)
      expect(file?("app/entities/components/post_author.rb")).to be(false)
    end

    it "writes only the migration" do
      migrations = Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
      other = Dir.glob(File.join(destination_root, "**/*.rb")) - migrations

      aggregate_failures do
        expect(migrations.size).to eq(1)
        expect(other).to be_empty
      end
    end
  end

  # A namespaced target class name is preserved verbatim in the reminder and the
  # column derives from the relation, not the target.
  describe "a namespaced target" do
    before { run_generator %w[Post owner:Accounts::User] }

    it "derives the column from the relation name" do
      expect(migration("create_post_owners")).to match(/t\.uuid :owner_id, default: nil/)
    end
  end

  describe "a bad argument" do
    it "rejects an argument that is not name:Target" do
      expect { run_generator %w[Post author] }.to raise_error(Thor::Error, /name:Target/)
    end
  end

  # Two generators invoked in the same second must not collide (same guarantee
  # the component generator makes).
  describe "migration numbering" do
    it "does not collide when run twice in the same second" do
      run_generator %w[Post author:User]
      run_generator %w[Comment parent:User]

      versions = Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
                    .map { |path| File.basename(path).split("_").first }

      aggregate_failures do
        expect(versions.size).to eq(2)
        expect(versions.uniq.size).to eq(2)
      end
    end
  end
end
