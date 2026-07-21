# frozen_string_literal: true

class Comments::LikesController < ApplicationController
  def create
    comment = Comment.find(params[:comment_id])
    comment.likes.increment!
    redirect_back fallback_location: comment.post || root_path, notice: "Liked."
  end
end
