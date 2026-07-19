# frozen_string_literal: true

require_relative "generator_helper"

# RFC-0008: `rails g ecs_rails:install`.
#
# The emitted migration must match the shape of spec/support/schema.rb's
# `entities` table, which is itself docs/architecture.md §2.
RSpec.describe EcsRails::Generators::InstallGenerator, type: :generator do
  describe "the migration" do
    subject(:contents) { migration("ecs_rails_create_entities") }

    before { run_generator }

    it "is generated" do
      expect(migration_paths("ecs_rails_create_entities").size).to eq(1)
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
    # Asserts on the column declaration, not on the word: the migration's own
    # comment explains why updated_at is absent, and so mentions it.
    it "does not declare an updated_at column" do
      expect(contents).not_to match(/^\s*t\.\w+ :updated_at/)
    end

    it "does not use t.timestamps, which would add updated_at" do
      expect(contents).not_to match(/t\.timestamps/)
    end

    it "targets the running ActiveRecord version" do
      expect(contents).to match(
        /class EcsRailsCreateEntities < ActiveRecord::Migration\[\d+\.\d+\]/
      )
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
