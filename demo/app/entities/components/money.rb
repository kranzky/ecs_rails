# frozen_string_literal: true

# Money, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`monies`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Money` (or under a slot,
# `component Money, prefix: :label`); the table already exists.
class Money < ApplicationComponent
  include EcsRails::Catalogue::Money
end
