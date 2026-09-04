# frozen_string_literal: true

# The one component every `relates_to` is a row of (ADR-0017). Every
# relationship in this application lives in the `relationships` table; the slot
# is the relationship name, `target_id` the entity pointed at.
#
#   class Post < ApplicationEntity
#     relates_to :author, User        # post.author, post.author=, post.author_relationship
#   end
#
# A catalogue component (ADR-0018): the behaviour lives in the gem's concern,
# and this application owns the constant. Add local behaviour here if you need
# it. If your domain already has a `Relationship`, rename this class and set
# `config.relationship_class_name` in config/initializers/ecs_rails.rb.
class Relationship < ApplicationComponent
  include EcsRails::Catalogue::Relationship
end
