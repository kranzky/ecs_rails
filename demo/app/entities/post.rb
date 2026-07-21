# frozen_string_literal: true

class Post < ApplicationEntity
  component Title, except: [:text]
  component Body, except: [:text]
  component PublishState
  component Likes
  relates_to :author, User      # post.author => User; no component file

  # "All published posts", via the query DSL (RFC-0010). with_component applies
  # the entity-model scope and compiles to a correlated EXISTS, so a PublishState
  # shared with another entity type cannot leak in. See docs/friction-log.md.
  def self.published
    with_component(PublishState, state: "published").order(created_at: :desc)
  end
end
