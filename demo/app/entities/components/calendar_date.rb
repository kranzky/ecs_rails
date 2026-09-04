# frozen_string_literal: true

# CalendarDate, from the ECS Rails catalogue (ADR-0018). The
# behaviour, validations and table (`calendar_dates`) come from the gem's
# concern; this application owns the constant. Add local behaviour here. Declare
# it on an entity with `component CalendarDate` (or under a slot,
# `component CalendarDate, prefix: :label`); the table already exists.
class CalendarDate < ApplicationComponent
  include EcsRails::Catalogue::CalendarDate
end
