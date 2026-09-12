# frozen_string_literal: true

require "spec_helper"

# Pins RFC-0012's ECS-24 amendment: every normal persistence path must enforce
# the declared target type, including foreign-key assignment and saves through
# the shared component. Otherwise a form can create a link the object writer
# would reject, despite a green entity save.
RSpec.describe "relationship target validation" do
  it "rejects a wrong-type ID before inserting a new owner or relationship" do
    post = Post.new(author_id: Team.create!.id)

    expect { expect(post.save).to be false }.not_to change(ApplicationEntity, :count)
    expect(Relationship.where(entity_id: post.id)).not_to exist
    expect(post.errors[:"author_relationship.target"]).to include("must be a User")
    expect { post.save! }.to raise_error(ActiveRecord::RecordInvalid, /Author relationship target must be a User/)
  end

  it "rejects wrong-type flat mass assignment through create!" do
    wrong_id = Post.create!.id

    expect { Post.create!(author_id: wrong_id) }
      .to raise_error(ActiveRecord::RecordInvalid, /must be a User/)
  end

  it "preserves the existing target when an ID replacement fails" do
    user = User.create!
    post = Post.create!(author: user)
    expect(post.author).to eq user # exercise the previously cached target
    post.author_id = Team.create!.id

    expect(post.save).to be false
    expect(post.reload.author).to eq user
  end

  it "allows a valid ID replacement after a failed validation" do
    post = Post.create!(author: User.create!)
    post.author_id = Team.create!.id
    expect(post.save).to be false
    replacement = User.create!
    post.author_id = replacement.id

    expect(post.save).to be true
    expect(post.reload.author).to eq replacement
  end

  it "validates a relationship saved directly after loading it independently" do
    post = Post.create!(author: User.create!)
    relationship = Relationship.find_by!(entity_id: post.id, slot: "author")
    relationship.target_id = Team.create!.id

    expect(relationship.save).to be false
    expect(relationship.errors[:target]).to include("must be a User")
    expect { relationship.save! }.to raise_error(ActiveRecord::RecordInvalid)
    expect(post.reload.author).to be_a User
  end

  it "validates a new relationship created directly from its owner and slot" do
    relationship = Relationship.new(entity: Post.create!, slot: "author", target_id: Team.create!.id)

    expect(relationship.save).to be false
    expect(relationship.errors[:target]).to include("must be a User")
  end

  it "reports a nonexistent target ID as a validation error" do
    post = Post.new(author_id: SecureRandom.uuid)

    expect(post.save).to be false
    expect(post.errors[:"author_relationship.target"]).to include("must exist")
    expect { post.save! }.to raise_error(ActiveRecord::RecordInvalid, /must exist/)
  end

  it "accepts a subclass through ID assignment" do
    stub_const("Admin", Class.new(User))
    admin = Admin.create!

    expect(Post.create!(author_id: admin.id).reload.author).to eq admin
  end

  it "accepts clearing a target by ID" do
    post = Post.create!(author: User.create!)
    post.author_id = nil

    expect(post.save).to be true
    expect(post.reload.author).to be_nil
  end

  it "accepts a relationship nullified by target deletion" do
    user = User.create!
    post = Post.create!(author: user)
    user.destroy!
    post.reload.author

    expect(post.save).to be true
    expect(post.reload.author).to be_nil
  end

  it "does not look up an object-assigned target again during validation" do
    post = Post.new(author: User.create!)

    expect(entity_selects { expect(post.valid?).to be true }).to be_empty
  end

  it "does not look up preloaded targets again during validation" do
    post = Post.create!(author: User.create!)
    loaded = Post.includes_related(:author).find(post.id)
    loaded.author

    expect(entity_selects { expect(loaded.valid?).to be true }).to be_empty
  end

  def entity_selects
    queries = []
    subscriber = lambda do |*args|
      sql = args.last[:sql]
      queries << sql if sql.match?(/SELECT.*FROM "entities"/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    queries
  end
end
