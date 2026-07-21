# frozen_string_literal: true

class PostsController < ApplicationController
  def index
    # Preload the components the index renders (RFC-0011), plus the nested
    # author-name hop through the :author relationship (RFC-0012). Turns an
    # N+1 into a bounded query count.
    @posts = Post.published
                 .includes_components(Title, Body, Likes)
                 .preload(author_relationship: { author: :name })
  end

  def show
    @post = Post.find(params[:id])
    # Comments on this post — by relationship name (RFC-0013), no backing class.
    # The author name is a two-hop preload (kept explicit, an RFC-0013 non-goal).
    @comments = Comment
                .with_related(:post, @post)
                .includes_components(Body, Likes)
                .preload(author_relationship: { author: :name })
                .order(created_at: :asc)
    @comment = Comment.new
    @authors = User.all
  end

  def new
    @post = Post.new
    @authors = User.all
  end

  def create
    post = Post.new
    post.title.text = post_params[:title]
    post.body.text = post_params[:body]
    post.author = User.find(post_params[:author_id]) if post_params[:author_id].present?
    post.publish_state.state = post_params[:publish] == "1" ? "published" : "draft"
    post.likes.count = 0

    if post.save
      redirect_to post, notice: "Post published."
    else
      @post = post
      @authors = User.all
      render :new, status: :unprocessable_entity
    end
  end

  private

  def post_params
    params.require(:post).permit(:title, :body, :author_id, :publish)
  end
end
