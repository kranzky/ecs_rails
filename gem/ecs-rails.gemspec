# frozen_string_literal: true

require_relative "lib/ecs_rails/version"

Gem::Specification.new do |spec|
  spec.name        = "ecs-rails"
  spec.version     = EcsRails::VERSION
  spec.authors     = ["Jason Hutchens"]
  spec.email       = ["jasonhutchens@gmail.com"]

  spec.summary     = "An Entity-Component-System reimagining of ActiveRecord."
  spec.description = <<~DESC
    ECS Rails extends ActiveRecord with an Entity-Component-System persistence
    architecture inspired by Flecs, while remaining idiomatic Rails. Entities
    are lightweight identity records composed from reusable, lazily persisted
    components that encapsulate both data and behaviour.
  DESC
  spec.homepage    = "https://github.com/kranzky/rails-ecs"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord",  ">= 7.1", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "railties",      ">= 7.1", "< 9.0"
end
