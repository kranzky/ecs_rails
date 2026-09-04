# frozen_string_literal: true

# Link, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`links`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Link` (or under a slot,
# `component Link, prefix: :label`); the table already exists.
class Link < ApplicationComponent
  include EcsRails::Catalogue::Link
end
