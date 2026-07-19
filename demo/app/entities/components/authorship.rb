# frozen_string_literal: true

# A relationship component (ADR-0006). Named for the relationship; its
# association is named for the target, so `post.author` (delegated) returns the
# User. Naming the component `Author` with a `belongs_to :author` would collide
# with the generated reader — see the ADR-0006 amendment.
class Authorship < ApplicationComponent
  belongs_to :author, class_name: "User", foreign_key: :author_id, optional: true
end
