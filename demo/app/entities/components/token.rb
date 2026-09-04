# frozen_string_literal: true

# Token, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`tokens`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Token` (or under a slot,
# `component Token, prefix: :label`); the table already exists.
class Token < ApplicationComponent
  include EcsRails::Catalogue::Token
end
