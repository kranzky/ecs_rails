# frozen_string_literal: true

class Comment < ApplicationEntity
  component Body                # comment.body_text (ADR-0016)
  component Likes
  relates_to :author, User
  relates_to :post, Post
end
