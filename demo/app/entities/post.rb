# frozen_string_literal: true

# A post: two Texts, a State, a Counter and an author — all catalogue
# components under slots, one row each in the shared tables. No migration.
class Post < ApplicationEntity
  component Text,    prefix: :title                              # post.title (the String), post.title_text (the Text)
  component Text,    prefix: :body                               # post.body
  component State,   prefix: :publish, states: %w[draft published] # post.publish_state.status
  component Counter, prefix: :likes                              # post.likes (the Integer), post.likes_counter
  component SearchVector                                         # rebuilt by Demo::Indexer from the post's Texts
  relates_to :author, User                                       # post.author => User
  # The parent side (RFC-0015): a real collection over the shared relationships
  # table; the child (Comment) is inferred from the name and resolved on first
  # use, never at load. dependent: :destroy removes the link rows with the post,
  # so no comment is left pointing at nothing.
  has_many :comments, via: :post, dependent: :destroy            # post.comments

  # "All published posts", via the query DSL (RFC-0010): the State rows in slot
  # "publish" whose status is published, scoped to posts. Compiles to a
  # correlated EXISTS, so a State on another entity type cannot leak in.
  def self.published
    with_component(State, prefix: :publish, status: "published").order(created_at: :desc)
  end

  # Full-text search over the SearchVector the Indexer maintains (RFC-0018: a
  # block on with_component runs as the component's relation, so the
  # component's own `matching` scope is the condition).
  def self.searching(query)
    return all if query.blank?

    with_component(SearchVector) { matching(query) }
  end

  # "Most liked first" — ordering by a component's value is a different
  # mechanism from filtering (RFC-0018): a scalar subquery in ORDER BY.
  def self.most_liked
    reorder(nil).order_by_component(Counter, prefix: :likes, direction: :desc).order(created_at: :desc)
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
