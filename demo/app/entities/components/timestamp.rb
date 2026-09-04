# frozen_string_literal: true

# Timestamp, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`timestamps`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Timestamp` (or under a slot,
# `component Timestamp, prefix: :label`); the table already exists.
class Timestamp < ApplicationComponent
  include EcsRails::Catalogue::Timestamp
end
