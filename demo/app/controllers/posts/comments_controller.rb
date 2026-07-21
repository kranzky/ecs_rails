# frozen_string_literal: true

class Posts::CommentsController < ApplicationController
  def create
    post = Post.find(params[:post_id])
    comment = Comment.new
    comment.body.text = params.dig(:comment, :body)
    comment.post = post
    comment.author = User.find(params[:comment][:author_id]) if params.dig(:comment, :author_id).present?
    comment.likes.count = 0

    if comment.save
      redirect_to post, notice: "Comment added."
    else
      redirect_to post, alert: comment.errors.full_messages.to_sentence.presence || "Comment could not be saved."
    end
  end
end
