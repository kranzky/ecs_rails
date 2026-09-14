# frozen_string_literal: true

# The base class for every component in this application.
#
# A component is an ordinary ActiveRecord model that owns one table and belongs
# to exactly one entity. It may hold behaviour as well as data, and it must
# never reference an entity subclass.
#
# The install generator supplies the catalogue components. For a bespoke
# component with its own table, generate a new name:
#
#   rails g ecs_rails:component Widget size:integer
#
# See docs/architecture.md §1.
class ApplicationComponent < EcsRails::Component
  self.abstract_class = true
end
