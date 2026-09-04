# frozen_string_literal: true

class Posts::CommentsController < ApplicationController
  def create
    post = Post.find(params[:post_id])
    return redirect_to(post, alert: "You can't comment on a draft.") if post.draft?

    # Flat mass assignment (ADR-0016). `post:` is a relationship writer, which
    # relates_to leaves bare on purpose; the rest are prefixed component keys.
    comment = Comment.new(body_text: cap(params.dig(:comment, :body), 2000), post: post, likes_count: 0)
    comment.author = User.find(params[:comment][:author_id]) if params.dig(:comment, :author_id).present?

    if comment.save
      redirect_to post, notice: "Comment added."
    else
      redirect_to post, alert: comment.errors.full_messages.to_sentence.presence || "Comment could not be saved."
    end
  end
end
