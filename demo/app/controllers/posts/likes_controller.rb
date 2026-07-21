# frozen_string_literal: true

class Posts::LikesController < ApplicationController
  def create
    post = Post.find(params[:post_id])
    post.likes.increment!
    redirect_back fallback_location: post, notice: "Liked."
  end
end
