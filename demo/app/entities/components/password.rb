# frozen_string_literal: true

# Password, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`passwords`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Password` (or under a slot,
# `component Password, prefix: :label`); the table already exists.
class Password < ApplicationComponent
  include EcsRails::Catalogue::Password
end
