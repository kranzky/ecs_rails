# frozen_string_literal: true

require_relative "lib/ecs_rails/version"

Gem::Specification.new do |spec|
  # Published as "ecs_on_rails". RubyGems treats "-", "_" and case as
  # equivalent when comparing names, so "ecs_rails" and "ecs-rails" both collide
  # with an existing unrelated gem and are permanently unavailable. The module,
  # the require path and the generators stay "ecs_rails" / EcsRails — see
  # docs/adr/0007-monorepo-and-licensing.md. lib/ecs_on_rails.rb is the shim
  # Bundler.require needs, since Bundler requires a gem by its own name.
  spec.name        = "ecs_on_rails"
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
  # The gem lives in gem/ of a monorepo, so these must not assume the repo root:
  # a bare /blob/main/CHANGELOG.md 404s (there is no root changelog).
  spec.metadata["source_code_uri"]      = "#{spec.homepage}/tree/main/gem"
  spec.metadata["changelog_uri"]        = "#{spec.homepage}/blob/main/gem/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]      = "#{spec.homepage}/issues"
  # The narrative documentation (architecture, ADRs, RFCs) is the real reference
  # for this gem, so Documentation points there rather than at the auto-generated
  # API listing, which stays available at rubydoc.info/gems/ecs_on_rails.
  spec.metadata["documentation_uri"]    = "#{spec.homepage}/blob/main/docs/README.md"
  # Require MFA to push/yank this gem (RubyGems best practice). Needs MFA
  # enabled on the pushing account; remove this line if that is not set up.
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord",  ">= 7.1", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.1", "< 9.0"
  spec.add_dependency "railties",      ">= 7.1", "< 9.0"
end
