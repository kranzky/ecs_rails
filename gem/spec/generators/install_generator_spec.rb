# frozen_string_literal: true

require_relative "generator_helper"

# RFC-0008: `rails g ecs_rails:install`.
#
# The emitted migration must match the shape of spec/support/schema.rb's
# `entities` and `relationships` tables, which are themselves
# docs/architecture.md §2 (ADR-0002, ADR-0017).
RSpec.describe EcsRails::Generators::InstallGenerator, type: :generator do
  describe "the migration" do
    subject(:contents) { migration("ecs_rails_install") }

    before { run_generator }

    it "is generated" do
      expect(migration_paths("ecs_rails_install").size).to eq(1)
    end

    it "enables pgcrypto" do
      expect(contents).to match(/enable_extension "pgcrypto"/)
    end

    it "gives entities a UUID primary key defaulting to gen_random_uuid()" do
      expect(contents).to match(
        /create_table :entities, id: :uuid, default: -> \{ "gen_random_uuid\(\)" \}/
      )
    end

    it "declares model as a non-null indexed string" do
      expect(contents).to match(/t\.string :model, null: false, index: true/)
    end

    it "declares created_at" do
      expect(contents).to match(/t\.datetime :created_at, null: false/)
    end

    # architecture.md §1: an entity is written once and never changes.
    #
    # Asserts on the column declaration inside the entities block, not on the
    # word: the migration's own comment explains why updated_at is absent, and
    # the relationships table further down legitimately has timestamps.
    def entities_block
      contents[/create_table :entities.*?^    end$/m]
    end

    it "does not declare an updated_at column on entities" do
      expect(entities_block).not_to match(/^\s*t\.\w+ :updated_at/)
    end

    it "does not use t.timestamps on entities, which would add updated_at" do
      expect(entities_block).not_to match(/t\.timestamps/)
    end

    it "targets the running ActiveRecord version" do
      expect(contents).to match(
        /class EcsRailsInstall < ActiveRecord::Migration\[\d+\.\d+\]/
      )
    end

    # ADR-0017: the shared relationships table is part of install, so a
    # `relates_to` never needs a migration.
    describe "the relationships table" do
      it "is created with the ADR-0017 columns" do
        aggregate_failures do
          expect(contents).to match(/create_table :relationships, id: :uuid/)
          expect(contents).to match(/t\.uuid\s+:entity_id,\s+null: false/)
          expect(contents).to match(/t\.string\s+:slot,\s+null: false, default: ""/)
          expect(contents).to match(/t\.uuid\s+:target_id/)
          expect(contents).to match(/t\.string\s+:owner_model, null: false/)
          expect(contents).to match(/t\.boolean :exclusive,\s+null: false, default: false/)
        end
      end

      it "makes (entity_id, slot) unique and indexes (target_id, slot)" do
        aggregate_failures do
          expect(contents).to match(/add_index :relationships, \[:entity_id, :slot\], unique: true/)
          expect(contents).to match(/add_index :relationships, \[:target_id, :slot\]$/m)
        end
      end

      it "adds the partial unique index that enforces unique: true" do
        expect(contents).to match(
          /add_index :relationships, \[:target_id, :slot, :owner_model\], unique: true, where: "exclusive"/
        )
      end

      it "cascades on the owner and nullifies on the target" do
        aggregate_failures do
          expect(contents).to match(/column: :entity_id, on_delete: :cascade/)
          expect(contents).to match(/column: :target_id, on_delete: :nullify/)
        end
      end
    end
  end

  # ADR-0018 §4: the shared markers table is part of install too.
  describe "the markers table" do
    subject(:contents) { migration("ecs_rails_install") }

    before { run_generator }

      it "is created with entity_id, slot and timestamps only" do
        block = contents[/create_table :markers.*?^    end$/m]

        aggregate_failures do
          expect(block).to match(/t\.uuid\s+:entity_id, null: false/)
          expect(block).to match(/t\.string :slot,\s+null: false, default: ""/)
          expect(block).to match(/t\.timestamps/)
          expect(block.lines.grep(/^\s+t\./).size).to eq(3)
        end
      end

      it "makes (entity_id, slot) unique and cascades on the owner" do
        aggregate_failures do
          expect(contents).to match(/add_index :markers, \[:entity_id, :slot\], unique: true/)
          expect(contents).to match(/add_foreign_key :markers, :entities, column: :entity_id, on_delete: :cascade/)
        end
      end
  end

  # ADR-0018 §4: the one-line catalogue class every marker is a row of.
  describe "the Marker component" do
    before { run_generator }

    it "is created under app/entities/components and includes the gem's concern" do
      expect(file("app/entities/components/marker.rb"))
        .to match(/class Marker < ApplicationComponent/)
        .and match(/include EcsRails::Catalogue::Marker/)
    end
  end

  # ADR-0017 / ADR-0018: the one-line catalogue class every relates_to is a row of.
  describe "the Relationship component" do
    before { run_generator }

    it "is created under app/entities/components" do
      expect(file("app/entities/components/relationship.rb"))
        .to match(/class Relationship < ApplicationComponent/)
    end

    it "includes the gem's concern" do
      expect(file("app/entities/components/relationship.rb"))
        .to match(/include EcsRails::Catalogue::Relationship/)
    end
  end

  # ADR-0010: base classes land under the configured layout — entities at
  # app/entities, components at app/entities/components.
  describe "the base models" do
    before { run_generator }

    it "creates ApplicationEntity under app/entities" do
      expect(file("app/entities/application_entity.rb"))
        .to match(/class ApplicationEntity < EcsRails::Entity/)
    end

    it "marks ApplicationEntity abstract" do
      expect(file("app/entities/application_entity.rb"))
        .to match(/self\.abstract_class = true/)
    end

    it "creates ApplicationComponent under app/entities/components" do
      expect(file("app/entities/components/application_component.rb"))
        .to match(/class ApplicationComponent < EcsRails::Component/)
    end

    it "marks ApplicationComponent abstract" do
      expect(file("app/entities/components/application_component.rb"))
        .to match(/self\.abstract_class = true/)
    end
  end

  # ADR-0010: install writes config/initializers/ecs_rails.rb, which both records
  # the layout and collapses the nested components directory for Zeitwerk.
  describe "the initializer" do
    subject(:contents) { file("config/initializers/ecs_rails.rb") }

    before { run_generator }

    it "is created" do
      expect(file?("config/initializers/ecs_rails.rb")).to be(true)
    end

    it "sets entities_path to the default layout" do
      expect(contents).to match(/EcsRails\.configure do \|config\|/)
      expect(contents).to match(/config\.entities_path = "app\/entities"/)
    end

    it "collapses the components directory for Zeitwerk" do
      expect(contents).to match(
        /Rails\.autoloaders\.main\.collapse\(/
      )
      expect(contents).to match(
        /Rails\.root\.join\(EcsRails\.config\.entities_path, "components"\)/
      )
    end
  end

  # ADR-0010's escape hatch: setting entities_path relocates the base classes.
  # (The initializer reflects the chosen path in its literal entities_path line.)
  describe "with entities_path overridden to app/models" do
    before do
      EcsRails.configure { |c| c.entities_path = "app/models" }
      run_generator
    end

    it "creates ApplicationEntity under app/models" do
      expect(file("app/models/application_entity.rb"))
        .to match(/class ApplicationEntity < EcsRails::Entity/)
    end

    it "creates ApplicationComponent under app/models/components" do
      expect(file("app/models/components/application_component.rb"))
        .to match(/class ApplicationComponent < EcsRails::Component/)
    end

    it "echoes the overridden path into the initializer" do
      expect(file("config/initializers/ecs_rails.rb"))
        .to match(/config\.entities_path = "app\/models"/)
    end
  end
end
