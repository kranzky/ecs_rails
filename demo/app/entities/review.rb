# frozen_string_literal: true

# A Comment with stars: the forum's shape plus a Rating. Points at a Product
# and an author through the shared relationships table.
class Review < ApplicationEntity
  component Text,    prefix: :body    # review.body
  component Rating                    # review.rating_stars
  component Counter, prefix: :likes   # review.likes
  relates_to :author,  User
  relates_to :product, Product
end
