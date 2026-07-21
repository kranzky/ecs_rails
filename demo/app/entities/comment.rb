# frozen_string_literal: true

class Comment < ApplicationEntity
  component Body, except: [:text]
  component Likes
  relates_to :author, User
  relates_to :post, Post
end
