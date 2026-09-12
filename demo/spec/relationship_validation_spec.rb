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
end
