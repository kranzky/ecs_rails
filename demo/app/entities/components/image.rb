# frozen_string_literal: true

# Image, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`images`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Image` (or under a slot,
# `component Image, prefix: :label`); the table already exists.
class Image < ApplicationComponent
  include EcsRails::Catalogue::Image
end
