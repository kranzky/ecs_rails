# frozen_string_literal: true

require "spec_helper"

# RFC-0012 / ECS-25: an assigned new target is pending relationship state even
# before PostgreSQL assigns its UUID. The owner, link, target and its touched
# components must persist together or roll back together, never lose the link.
RSpec.describe "unsaved relationship targets" do
  [false, true].each do |persisted_owner|
    context "with a #{persisted_owner ? 'persisted' : 'new'} owner" do
      let(:post) { persisted_owner ? Post.create! : Post.new }

      [:save, :save!].each do |save_method|
        it "persists the target and its components through #{save_method}" do
          user = User.new(email_address: "ada@example.com")
          post.author = user

          expect(post.public_send(save_method)).to be true
          expect(user).to be_persisted
          expect(post.reload.author).to eq user
          expect(user.reload.email.address).to eq "ada@example.com"
        end

        it "rejects an invalid target through #{save_method} without writing rows" do
          post # build the owner outside the count assertion
          user = User.new(email_address: "invalid")
          post.author = user

          expect do
            if save_method == :save!
              expect { post.save! }.to raise_error(ActiveRecord::RecordInvalid)
            else
              expect(post.save).to be false
            end
          end.not_to change(ApplicationEntity, :count)

          expect(user).to be_new_record
          expect(post.errors.full_messages.join(" ")).to match(/Author relationship target.*invalid/i)
          expect(post.reload.author).to be_nil if persisted_owner
        end
      end

      it "does not persist an untouched relationship" do
        post.author

        expect { post.save! }.not_to change(Relationship, :count)
      end

      it "does not persist a target that was assigned and then cleared" do
        user = User.new(email_address: "ada@example.com")
        post.author = user
        post.author = nil

        expect { post.save! }.not_to change(Relationship, :count)
        expect(user).to be_new_record
        expect(post.reload.author).to be_nil
      end
    end
  end

  it "supports create! with a new target in flat mass assignment" do
    user = User.new
    post = Post.create!(author: user)

    expect(user).to be_persisted
    expect(post.reload.author).to eq user
  end

  it "replaces an existing target with a new target" do
    original = User.create!
    post = Post.create!(author: original)
    replacement = User.new(email_address: "new@example.com")
    post.author = replacement
    post.save!

    expect(post.reload.author).to eq replacement
    expect(replacement.reload.email.address).to eq "new@example.com"
    expect(User.exists?(original.id)).to be true
  end

  it "keeps the original target when the new target is invalid" do
    original = User.create!
    post = Post.create!(author: original)
    post.author = User.new(email_address: "invalid")

    expect(post.save).to be false
    expect(post.reload.author).to eq original
  end

  it "can save after the caller corrects the new target" do
    user = User.new(email_address: "invalid")
    post = Post.new(author: user)
    expect(post.save).to be false

    user.email_address = "ada@example.com"
    expect(post.save).to be true
    expect(post.reload.author).to eq user
  end

  it "validates without saving the target" do
    user = User.new(email_address: "ada@example.com")
    post = Post.new(author: user)

    expect { expect(post.valid?).to be true }.not_to change(ApplicationEntity, :count)
    expect(user).to be_new_record
  end

  it "saves a new target through the relationship component directly" do
    user = User.new(email_address: "ada@example.com")
    relationship = Relationship.new(entity: Post.create!, slot: "author", target: user)
    relationship.save!

    expect(relationship.reload.target).to eq user
    expect(user.reload.email.address).to eq "ada@example.com"
  end

  it "rolls back the target and its components if the owner transaction later fails" do
    user = User.new(email_address: "ada@example.com")
    post = Post.new(author: user)

    expect do
      ApplicationEntity.transaction(requires_new: true) do
        post.save!
        expect(user).to be_persisted
        raise ActiveRecord::Rollback
      end
    end.not_to change(ApplicationEntity, :count)

    expect(Email.where(address: "ada@example.com")).not_to exist
    expect(Relationship.where(slot: "author")).not_to exist
    expect(post).to be_new_record
    expect(user).to be_new_record
  end
end
