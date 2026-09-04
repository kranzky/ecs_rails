# frozen_string_literal: true

# Text, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`texts`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Text` (or under a slot,
# `component Text, prefix: :label`); the table already exists.
class Text < ApplicationComponent
  include EcsRails::Catalogue::Text
end
