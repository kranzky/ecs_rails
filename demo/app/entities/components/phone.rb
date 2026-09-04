# frozen_string_literal: true

# Phone, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`phones`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Phone` (or under a slot,
# `component Phone, prefix: :label`); the table already exists.
class Phone < ApplicationComponent
  include EcsRails::Catalogue::Phone
end
