# frozen_string_literal: true

class Comment < ApplicationEntity
  component Text,    prefix: :body    # comment.body_text
  component Counter, prefix: :likes   # comment.likes_counter
  relates_to :author, User
  relates_to :post, Post
end
