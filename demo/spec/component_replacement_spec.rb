# frozen_string_literal: true

require "rails_helper"

# RFC-0006 / ECS-26: the catalogue-only demo must use the same replacement
# contract as bespoke components, including the prefixed delegation reader.
RSpec.describe "component replacement in the demo" do
  it "replaces a previously read user's email without duplicating the slot" do
    user = User.create!(email_address: "old@example.com")
    user.email
    replacement = Email.new(address: "new@example.com")
    user.email = replacement

    expect(user.email).to equal replacement
    expect(user.email_address).to eq "new@example.com"
    expect(Email.where(entity_id: user.id, slot: "").count).to eq 1
    expect(user.reload.email_address).to eq "new@example.com"
  end
end
