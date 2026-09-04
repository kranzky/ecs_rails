# frozen_string_literal: true

# Discard, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`discards`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Discard` (or under a slot,
# `component Discard, prefix: :label`); the table already exists.
class Discard < ApplicationComponent
  include EcsRails::Catalogue::Discard
end
