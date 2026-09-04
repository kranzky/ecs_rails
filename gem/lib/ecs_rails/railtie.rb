# frozen_string_literal: true

require "rails/railtie"

module EcsRails
  # Hooks the gem into a host Rails application.
  class Railtie < ::Rails::Railtie
    # The registry keys entries by class name and resolves lazily, so it
    # survives development-mode reloading. See RFC-0002.
    config.to_prepare do
      EcsRails.registry.clear! if EcsRails.registry.respond_to?(:clear!)
    end

    # Inverse relationships (RFC-0015) are validated on first use because
    # checking at class-load time is unsafe under autoloading. When the app
    # eager-loads — production — every entity is present at boot, so check them
    # all now and fail to start rather than at the first request.
    config.after_initialize do |app|
      next unless app.config.eager_load

      EcsRails::Entity.descendants.reject(&:abstract_class?).each(&:validate_inverses!)
    end
  end
end
