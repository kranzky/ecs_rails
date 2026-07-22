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
    @post.publish_state.state = "published" # default the checkbox to checked
    @authors = User.all
  end

  def create
    post = Post.new
    assign(post, post_params)
    post.likes.count = 0

    if post.save
      redirect_to post, notice: post.published? ? "Post published." : "Draft saved."
    else
      @post = post
      @authors = User.all
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @post = Post.find(params[:id])
    @authors = User.all
  end

  def update
    post = Post.find(params[:id])
    assign(post, post_params)

    if post.save
      redirect_to post, notice: post.published? ? "Post published." : "Draft updated."
    else
      @post = post
      @authors = User.all
      render :edit, status: :unprocessable_entity
    end
  end

  # A one-click publish for a draft, from its show page.
  def publish
    post = Post.find(params[:id])
    post.publish!
    redirect_to post, notice: "Post published."
  end

  private

  # Shared by create and update. The publish checkbox always submits (check_box
  # renders a hidden "0"), so its key is always present on a form post.
  def assign(post, attrs)
    post.title.text = cap(attrs[:title], 120) if attrs.key?(:title)
    post.body.text = cap(attrs[:body], 5000) if attrs.key?(:body)
    post.author = User.find(attrs[:author_id]) if attrs[:author_id].present?
    post.publish_state.state = attrs[:publish] == "1" ? "published" : "draft" if attrs.key?(:publish)
  end

  def post_params
    params.require(:post).permit(:title, :body, :author_id, :publish)
  end
end
