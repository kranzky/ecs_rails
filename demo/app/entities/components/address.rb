# frozen_string_literal: true

# Address, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`addresses`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Address` (or under a slot,
# `component Address, prefix: :label`); the table already exists.
class Address < ApplicationComponent
  include EcsRails::Catalogue::Address
end
