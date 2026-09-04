# frozen_string_literal: true

# Marker, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`markers`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Marker` (or under a slot,
# `component Marker, prefix: :label`); the table already exists.
class Marker < ApplicationComponent
  include EcsRails::Catalogue::Marker
end
