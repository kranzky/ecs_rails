# frozen_string_literal: true

require "rails/railtie"

module Rorecs
  # Hooks the gem into a host Rails application.
  class Railtie < ::Rails::Railtie
    # The registry keys entries by class name and resolves lazily, so it
    # survives development-mode reloading. See RFC-0002.
    config.to_prepare do
      Rorecs.registry.clear! if Rorecs.registry.respond_to?(:clear!)
    end
  end
end
