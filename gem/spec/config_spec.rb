# frozen_string_literal: true

require "spec_helper"

# ADR-0010: EcsRails.config is the single knob for the generator directory
# layout. It is generator-only configuration — the runtime never reads it — but
# it is a process-wide singleton, so spec_helper.rb restores entities_path to its
# default after every example (see ECS_RAILS_CONFIG_DEFAULT_ENTITIES_PATH).
RSpec.describe EcsRails::Config do
  describe "the singleton accessor" do
    it "returns the same config across calls" do
      expect(EcsRails.config).to be(EcsRails.config)
    end
  end

  describe "entities_path" do
    it "defaults to app/entities" do
      expect(EcsRails.config.entities_path).to eq("app/entities")
    end
  end

  describe "components_path" do
    it "is derived as a components subdirectory of entities_path" do
      expect(EcsRails.config.components_path).to eq("app/entities/components")
    end

    it "tracks a changed entities_path" do
      EcsRails.configure { |c| c.entities_path = "app/models" }

      expect(EcsRails.config.components_path).to eq("app/models/components")
    end
  end

  describe ".configure" do
    it "yields the config so entities_path can be overridden" do
      EcsRails.configure { |c| c.entities_path = "lib/domain" }

      expect(EcsRails.config.entities_path).to eq("lib/domain")
    end
  end

  # The whole reason spec_helper.rb resets config after every example: prove the
  # override does not leak. This example asserts the default is back, which only
  # holds if the after hook restored it following the .configure examples above.
  describe "isolation between examples" do
    it "sees the default entities_path, unpolluted by earlier overrides" do
      expect(EcsRails.config.entities_path).to eq("app/entities")
    end
  end
end
