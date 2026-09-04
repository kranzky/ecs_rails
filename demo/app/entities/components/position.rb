# frozen_string_literal: true

# Position, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`positions`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Position` (or under a slot,
# `component Position, prefix: :label`); the table already exists.
class Position < ApplicationComponent
  include EcsRails::Catalogue::Position
end
