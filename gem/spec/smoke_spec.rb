# frozen_string_literal: true

require "spec_helper"

RSpec.describe "test harness" do
  it "connects to postgres" do
    expect(ActiveRecord::Base.connection).to be_active
  end

  it "has the entities table with no updated_at" do
    expect(ActiveRecord::Base.connection.columns(:entities).map(&:name))
      .to contain_exactly("id", "model", "created_at")
  end

  it "enforces the unique (entity_id, slot) invariant (ADR-0005 / ADR-0015)" do
    idx = ActiveRecord::Base.connection.indexes(:emails).find { |i| i.columns == %w[entity_id slot] }
    expect(idx.unique).to be true
  end

  it "has no entity_id-only unique index left (the slot index replaced it)" do
    expect(ActiveRecord::Base.connection.indexes(:emails).map(&:columns)).not_to include(["entity_id"])
  end

  it "loaded the gem" do
    expect(EcsRails::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
