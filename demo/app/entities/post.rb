# frozen_string_literal: true

# A post: two Texts, a State, a Counter and an author — all catalogue
# components under slots, one row each in the shared tables. No migration.
class Post < ApplicationEntity
  component Text,    prefix: :title                              # post.title (the String), post.title_text (the Text)
  component Text,    prefix: :body                               # post.body
  component State,   prefix: :publish, states: %w[draft published] # post.publish_state.status
  component Counter, prefix: :likes                              # post.likes (the Integer), post.likes_counter
  relates_to :author, User                                       # post.author => User

  # "All published posts", via the query DSL (RFC-0010): the State rows in slot
  # "publish" whose status is published, scoped to posts. Compiles to a
  # correlated EXISTS, so a State on another entity type cannot leak in.
  def self.published
    with_component(State, prefix: :publish, status: "published").order(created_at: :desc)
  end

  def published?
    publish_state.in?(:published)
  end

  def draft?
    !published?
  end

  # Behaviour on the entity: the State component's transition, logged.
  def publish!
    publish_state.transition!(:published, event: "publish")
  end
end
