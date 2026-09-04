# frozen_string_literal: true

# Name, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`names`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Name` (or under a slot,
# `component Name, prefix: :label`); the table already exists.
class Name < ApplicationComponent
  include EcsRails::Catalogue::Name
end
