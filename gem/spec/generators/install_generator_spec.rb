# frozen_string_literal: true

require_relative "generator_helper"

# RFC-0008: `rails g rorecs:install`.
#
# The emitted migration must match the shape of spec/support/schema.rb's
# `entities` table, which is itself docs/architecture.md §2.
RSpec.describe Rorecs::Generators::InstallGenerator, type: :generator do
  describe "the migration" do
    subject(:contents) { migration("rorecs_create_entities") }

    before { run_generator }

    it "is generated" do
      expect(migration_paths("rorecs_create_entities").size).to eq(1)
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
        /class RorecsCreateEntities < ActiveRecord::Migration\[\d+\.\d+\]/
      )
    end
  end

  describe "the base models" do
    before { run_generator }

    it "creates ApplicationEntity subclassing Rorecs::Entity" do
      expect(file("app/models/application_entity.rb"))
        .to match(/class ApplicationEntity < Rorecs::Entity/)
    end

    it "marks ApplicationEntity abstract" do
      expect(file("app/models/application_entity.rb"))
        .to match(/self\.abstract_class = true/)
    end

    it "creates ApplicationComponent subclassing Rorecs::Component" do
      expect(file("app/models/application_component.rb"))
        .to match(/class ApplicationComponent < Rorecs::Component/)
    end

    it "marks ApplicationComponent abstract" do
      expect(file("app/models/application_component.rb"))
        .to match(/self\.abstract_class = true/)
    end
  end
end
