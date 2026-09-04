# frozen_string_literal: true

# Role, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`roles`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Role` (or under a slot,
# `component Role, prefix: :label`); the table already exists.
class Role < ApplicationComponent
  include EcsRails::Catalogue::Role
end
