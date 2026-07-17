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

  it "enforces the unique entity_id invariant" do
    idx = ActiveRecord::Base.connection.indexes(:emails).find { |i| i.columns == ["entity_id"] }
    expect(idx.unique).to be true
  end

  it "loaded the gem" do
    expect(EcsRails::VERSION).to eq "0.1.0"
  end
end
