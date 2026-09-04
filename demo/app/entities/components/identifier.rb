# frozen_string_literal: true

# Identifier, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`identifiers`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Identifier` (or under a slot,
# `component Identifier, prefix: :label`); the table already exists.
class Identifier < ApplicationComponent
  include EcsRails::Catalogue::Identifier
end
