# frozen_string_literal: true

# Relationship, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`relationships`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Relationship` (or under a slot,
# `component Relationship, prefix: :label`); the table already exists.
class Relationship < ApplicationComponent
  include EcsRails::Catalogue::Relationship
end
