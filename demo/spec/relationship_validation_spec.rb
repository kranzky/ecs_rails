# frozen_string_literal: true

require "rails_helper"

# RFC-0012 / ECS-24: form-style IDs must respect the same relationship types
# as object assignments when the real demo models use the catalogue.
RSpec.describe "relationship validation in the demo" do
  it "rejects a seller company as a forum post's author" do
    post = Post.new(author_id: Company.create!.id)

    expect { expect(post.save).to be false }.not_to change(Post, :count)
    expect(post.errors[:"author_relationship.target"]).to include("must be a User")
  end

  it "saves a new forum author and their catalogue components with the post" do
    author = User.new(name_given: "Ada", email_address: "ada@example.com")
    post = Post.create!(author: author, title: "Composed together")

    expect(post.reload.author).to eq author
    expect(author.reload.name_given).to eq "Ada"
    expect(author.email_address).to eq "ada@example.com"
  end
end
