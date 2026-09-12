# frozen_string_literal: true

require "spec_helper"

# RFC-0006 / ECS-26: public component association APIs must not bypass the
# singleton, lazy persistence, or memo. Replacements are atomic; reload/reset
# discard both caches, while unsupported builders fail before touching data.
RSpec.describe "component replacement" do
  [false, true].each do |component_first|
    it "rejects operation/delegation collisions with component declared #{component_first ? 'first' : 'last'}" do
      stub_const("Builder", Class.new(ApplicationComponent) do
        self.table_name = "addresses"
        def build_email = :custom
      end)
      stub_const("Consumer", Class.new(ApplicationEntity))
      if component_first
        Consumer.component Email
        expect { Consumer.component Builder, prefix: false, only: [:build_email] }
          .to raise_error(EcsRails::DelegationConflict, /build_email/)
      else
        Consumer.component Builder, prefix: false, only: [:build_email]
        expect { Consumer.component Email }
          .to raise_error(EcsRails::DelegationConflict, /build_email/)
      end
    end
  end

  [false, true].each do |existing_row|
    context "with a #{existing_row ? 'persisted' : 'virtual'} component" do
      let(:user) { existing_row ? User.create!(email_address: "old@example.com") : User.create! }

      it "replaces an earlier read and keeps the reader and association coherent" do
        previous = user.email
        replacement = Email.new(address: "new@example.com")
        user.email = replacement

        expect(user.email).to equal replacement
        expect(user.association(:email).target).to equal replacement
        expect(user.email_address).to eq "new@example.com"
        expect(user.email?).to be true
        expect(Email.where(entity_id: user.id, slot: "").count).to eq 1
        expect(user.reload.email.address).to eq "new@example.com"
        expect(Email.exists?(previous.id)).to be false if existing_row
      end

      it "keeps the previous component when replacement validation fails" do
        previous = user.email

        expect { user.email = Email.new(address: "invalid") }
          .to raise_error(ActiveRecord::RecordInvalid)

        expect(user.email).to equal previous
        expect(user.email.address).to eq(existing_row ? "old@example.com" : nil)
        expect(user.reload.email.address).to eq(existing_row ? "old@example.com" : nil)
      end

      it "clears the slot with nil and keeps the reader virtual" do
        user.email
        user.email = nil

        expect(user.email).to be_a Email
        expect(user.email).not_to be_persisted
        expect(user.email?).to be false
        expect(user.reload.email.address).to be_nil
      end

      [:build_email, :create_email, :create_email!].each do |method|
        it "rejects #{method} before changing the slot" do
          previous = user.email

          expect { user.public_send(method, address: "new@example.com") }
            .to raise_error(EcsRails::InvalidComponent, /email.assign_attributes/)
          expect(user.email).to equal previous
          expect(user.reload.email.address).to eq(existing_row ? "old@example.com" : nil)
        end
      end
    end
  end

  it "defers replacement on a new owner until that owner is saved" do
    user = User.new
    user.email
    replacement = Email.new(address: "new@example.com")

    expect { user.email = replacement }.not_to change(Email, :count)
    expect(user.email).to equal replacement
    user.save!
    expect(user.reload.email.address).to eq "new@example.com"
  end

  it "keeps default-only replacement virtual on a new owner" do
    user = User.new
    user.email = Email.new

    expect { user.save! }.not_to change(Email, :count)
    expect(user.email?).to be false
  end

  it "keeps default-only replacement virtual on a persisted owner" do
    user = User.create!
    user.email = Email.new

    expect(user.email?).to be false
    expect { user.save! }.not_to change(Email, :count)
  end

  it "reports invalid pending replacements through the new owner's save contract" do
    user = User.new
    user.email = Email.new(address: "invalid")

    expect(user.save).to be false
    expect { user.save! }.to raise_error(ActiveRecord::RecordInvalid)
    expect(user.email.address).to eq "invalid"
  end

  it "assigns the declared slot without disturbing its sibling" do
    stub_const("Customer", Class.new(ApplicationEntity))
    Customer.component Address
    Customer.component Address, prefix: :business
    customer = Customer.create!(address_line1: "Home", business_address_line1: "Old office")
    customer.business_address
    replacement = Address.new(line1: "New office")
    customer.business_address = replacement

    expect(replacement.slot).to eq "business"
    expect(replacement.entity).to equal customer
    expect(customer.reload.business_address.line1).to eq "New office"
    expect(customer.address.line1).to eq "Home"
  end

  it "rejects moving a persisted component from another owner" do
    owner = User.create!(email_address: "owner@example.com")
    recipient = User.create!

    expect { recipient.email = owner.email }.to raise_error(EcsRails::InvalidComponent, /owner|slot/)
    expect(owner.reload.email.address).to eq "owner@example.com"
    expect(recipient.reload.email).not_to be_persisted
  end

  it "rejects the wrong component type" do
    expect { User.new.email = Address.new }.to raise_error(EcsRails::InvalidComponent, /Email/)
  end

  it "rejects moving a virtual component from another new owner" do
    owner = User.new
    recipient = User.new

    expect { recipient.email = owner.email }.to raise_error(EcsRails::InvalidComponent, /owner|slot/)
    expect(owner.email.entity).to equal owner
  end

  it "rejects moving a persisted component between slots on the same owner" do
    stub_const("Customer", Class.new(ApplicationEntity))
    Customer.component Address
    Customer.component Address, prefix: :business
    customer = Customer.create!(address_line1: "Home")

    expect { customer.business_address = customer.address }
      .to raise_error(EcsRails::InvalidComponent, /owner|slot/)
    expect(customer.reload.address.line1).to eq "Home"
    expect(customer.business_address).not_to be_persisted
  end

  it "preserves the old row when a caller rescues failure inside a transaction" do
    user = User.create!(email_address: "old@example.com")
    previous = user.email

    ApplicationEntity.transaction(requires_new: true) do
      expect { user.email = Email.new(address: "invalid") }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(user.email).to equal previous
      expect(user.association(:email).target).to equal previous
      expect(user.email).to be_persisted
      user.email.address = "corrected@example.com"
      user.save!
    end

    expect(user.reload.email.id).to eq previous.id
    expect(user.email.address).to eq "corrected@example.com"
  end

  it "can assign the current component without creating a duplicate" do
    user = User.create!(email_address: "old@example.com")
    component = user.email
    component.address = "new@example.com"

    expect { user.email = component }.not_to change(Email, :count)
    expect(user.reload.email.address).to eq "new@example.com"
  end

  it "rolls back a replacement with its surrounding transaction" do
    user = User.create!(email_address: "old@example.com")
    old_id = user.email.id

    ApplicationEntity.transaction(requires_new: true) do
      user.email = Email.new(address: "new@example.com")
      expect(user.reload.email.address).to eq "new@example.com"
      raise ActiveRecord::Rollback
    end

    expect(user.reload.email.id).to eq old_id
    expect(user.email.address).to eq "old@example.com"
    expect(Email.where(entity_id: user.id).count).to eq 1
  end

  [:reload_email, :reset_email].each do |method|
    it "clears the lazy memo through #{method}" do
      user = User.create!(email_address: "old@example.com")
      previous = user.email
      Email.find(previous.id).update!(address: "external@example.com")
      user.public_send(method)

      expect(user.email.address).to eq "external@example.com"
      expect(user.association(:email).target).to equal user.email
    end
  end

  it "returns a virtual component when reloading a missing row" do
    user = User.create!
    user.email.address = "unsaved@example.com"

    expect(user.reload_email).to be_a Email
    expect(user.email.address).to be_nil
    expect(user.email?).to be false
  end
end
