# frozen_string_literal: true

# SearchVector, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`search_vectors`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component SearchVector` (or under a slot,
# `component SearchVector, prefix: :label`); the table already exists.
class SearchVector < ApplicationComponent
  include EcsRails::Catalogue::SearchVector
end
