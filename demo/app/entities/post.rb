# frozen_string_literal: true

class Post < ApplicationEntity
  component Title, except: [:text]
  component Body, except: [:text]
  component Authorship
  component PublishState
  component Likes

  # "All published posts", via the query DSL (RFC-0010). Replaces the
  # hand-rolled subquery whose correctness silently rode Post's default_scope.
  # `with_component` applies the entity-model scope itself and compiles to a
  # correlated EXISTS, so a PublishState shared with another entity type (the
  # proposal shares it with Group) cannot leak in. See docs/friction-log.md and
  # ADR-0011.
  def self.published
    with_component(PublishState, state: "published").order(created_at: :desc)
  end
end
