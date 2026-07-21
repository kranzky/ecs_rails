# frozen_string_literal: true

class PostsController < ApplicationController
  def index
    # Preload the components the index renders (RFC-0011), plus the nested
    # author-name hop: post.author is a User reached through the :author
    # relationship (RFC-0012), whose backing reader is author_relationship, so
    # the Name is two hops out and needs standard AR nesting. Drops the index
    # from N+1 (one query per component per row) to a bounded handful.
    @posts = Post.published
                 .includes_components(Title, Body, Likes)
                 .preload(author_relationship: { author: :name })
  end

  def show
    @post = Post.find(params[:id])
  end

  def new
    @post = Post.new
  end

  def create
    author = User.first || seed_author
    post = Post.new
    post.title.text = post_params[:title]
    post.body.text = post_params[:body]
    post.author = author
    post.publish_state.state = post_params[:publish] == "1" ? "published" : "draft"

    if post.save
      redirect_to post, notice: "Post created."
    else
      @post = post
      render :new, status: :unprocessable_entity
    end
  end

  private

  def post_params
    params.require(:post).permit(:title, :body, :publish)
  end

  # The demo has no auth; every post needs an author, so fall back to a seed user.
  def seed_author
    User.create!.tap do |u|
      u.name.first = "Guest"
      u.email.address = "guest@example.com"
      u.save!
    end
  end
end
