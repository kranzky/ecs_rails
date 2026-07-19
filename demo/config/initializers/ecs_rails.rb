# frozen_string_literal: true

# ECS Rails directory layout.
#
# Entities live in app/entities, components in app/entities/components. Rails
# already treats app/entities as an autoload root (app/entities/user.rb -> User),
# but the nested components/ directory would namespace its classes as
# Components::Name. Collapsing it makes app/entities/components/name.rb -> Name,
# top-level — the same mechanism Rails uses for app/models/concerns.
#
# entities_path is the single source of truth: the ecs_rails:component generator
# reads it to decide where to place new components.
EcsRails.configure do |config|
  config.entities_path = "app/entities"
end

Rails.autoloaders.main.collapse(
  Rails.root.join(EcsRails.config.entities_path, "components")
)
