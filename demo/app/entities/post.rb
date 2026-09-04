# frozen_string_literal: true

class Post < ApplicationEntity
  # Delegation is reader-prefixed (ADR-0016): post.title_text, post.body_text.
  # Title and Body both carry a `text` column; before ADR-0016 that was a
  # DelegationConflict resolved with `except: [:text]`, which dropped the
  # delegation altogether. Now both coexist and neither needs an option.
  component Title
  component Body
  # The prefix would be redundant here — post.publish_state_state — so opt out
  # and take the bare name: post.state.
  component PublishState, prefix: false
  component Likes               # post.likes_count; post.likes.increment! for the verb
  relates_to :author, User      # post.author => User; no component file

  # "All published posts", via the query DSL (RFC-0010). with_component applies
  # the entity-model scope and compiles to a correlated EXISTS, so a PublishState
  # shared with another entity type cannot leak in. See docs/friction-log.md.
  def self.published
    with_component(PublishState, state: "published").order(created_at: :desc)
  end

  def published?
    state == "published"
  end

  def draft?
    !published?
  end

  # Behaviour on the entity: flip the PublishState component and persist.
  def publish!
    self.state = "published"
    save!
  end
end
