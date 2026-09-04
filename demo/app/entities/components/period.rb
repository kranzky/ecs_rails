# frozen_string_literal: true

# Period, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`periods`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Period` (or under a slot,
# `component Period, prefix: :label`); the table already exists.
class Period < ApplicationComponent
  include EcsRails::Catalogue::Period
end
