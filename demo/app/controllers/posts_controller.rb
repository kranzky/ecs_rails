# frozen_string_literal: true

class PostsController < ApplicationController
  def index
    @posts = Post.published
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
