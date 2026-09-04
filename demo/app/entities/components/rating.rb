# frozen_string_literal: true

# Rating, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`ratings`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Rating` (or under a slot,
# `component Rating, prefix: :label`); the table already exists.
class Rating < ApplicationComponent
  include EcsRails::Catalogue::Rating
end
