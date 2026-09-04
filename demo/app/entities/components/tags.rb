# frozen_string_literal: true

# Tags, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`tags`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Tags` (or under a slot,
# `component Tags, prefix: :label`); the table already exists.
class Tags < ApplicationComponent
  include EcsRails::Catalogue::Tags
end
