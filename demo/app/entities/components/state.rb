# frozen_string_literal: true

# State, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`states`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component State` (or under a slot,
# `component State, prefix: :label`); the table already exists.
class State < ApplicationComponent
  include EcsRails::Catalogue::State
end
