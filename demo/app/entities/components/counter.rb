# frozen_string_literal: true

# Counter, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`counters`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Counter` (or under a slot,
# `component Counter, prefix: :label`); the table already exists.
class Counter < ApplicationComponent
  include EcsRails::Catalogue::Counter
end
