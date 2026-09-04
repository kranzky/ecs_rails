# frozen_string_literal: true

class Comment < ApplicationEntity
  component Text,    prefix: :body    # comment.body
  component Counter, prefix: :likes   # comment.likes
  relates_to :author, User
  relates_to :post, Post
end
