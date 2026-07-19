# frozen_string_literal: true

class Comment < ApplicationEntity
  component Body, except: [:text]
  component Authorship
  component Likes
end
