# frozen_string_literal: true

# Geolocation, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`geolocations`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component Geolocation` (or under a slot,
# `component Geolocation, prefix: :label`); the table already exists.
class Geolocation < ApplicationComponent
  include EcsRails::Catalogue::Geolocation
end
