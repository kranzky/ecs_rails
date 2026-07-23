# frozen_string_literal: true

require_relative "lib/ecs_rails/version"

Gem::Specification.new do |spec|
  spec.name        = "ecs_rails"
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
  spec.homepage    = "https://github.com/kranzky/ecs_rails"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  # homepage_uri is covered by spec.homepage above; specifying both (identical)
  # trips a rubygems build warning, so it is left out here.
  spec.metadata["source_code_uri"]      = spec.homepage
  spec.metadata["changelog_uri"]        = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]      = "#{spec.homepage}/issues"
  # Require MFA to push/yank this gem (RubyGems best practice). Needs MFA
  # enabled on the pushing account; remove this line if that is not set up.
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord",  ">= 7.1", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "railties",      ">= 7.1", "< 9.0"
end
