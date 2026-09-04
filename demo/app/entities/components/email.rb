# frozen_string_literal: true

# Email, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`emails`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Email` (or under a slot,
# `component Email, prefix: :label`); the table already exists.
class Email < ApplicationComponent
  include EcsRails::Catalogue::Email

  # The catalogue allows a nil address (a component may be virtual); this board
  # requires one. Local behaviour on the one-line class is the idiom.
  validates :address, presence: true
end
