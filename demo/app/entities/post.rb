# frozen_string_literal: true

class Post < ApplicationEntity
  component Title, except: [:text]
  component Body, except: [:text]
  component Authorship
  component PublishState
  component Likes

  # The query the proposal writes as `Post.with(PublishState)` — which doesn't
  # exist yet, and whose name collides with ActiveRecord's own `.with` (CTEs).
  # Hand-rolled across the entity/component split until a query DSL lands.
  # See docs/friction-log.md.
  #
  # Note the entity-model filter is *not* in the component subquery.
  # `PublishState.where(state: "published")` is blind to entity type — it matches
  # published PublishStates on any entity that has one (the proposal shares
  # PublishState with Group). The filter to Posts comes from the OUTER `where`,
  # because `Post` carries a default_scope of `model = 'posts'` (ADR-0002). The
  # two combine as `model = 'posts' AND id IN (...)`.
  #
  # That default_scope is therefore load-bearing here: `Post.unscoped.published`,
  # or loading these ids through `ApplicationEntity.where(id:)`, would leak
  # Groups. A real query DSL must apply the entity-model scope itself so callers
  # don't have to know this.
  def self.published
    ids = PublishState.where(state: "published").select(:entity_id)
    where(id: ids).order(created_at: :desc)
  end
end
