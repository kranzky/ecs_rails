# frozen_string_literal: true

# Bundler requires a gem by its own name, so `gem "ecs-rails"` in a host app's
# Gemfile makes Bundler.require attempt `require "ecs-rails"` — with the hyphen.
# Ruby's require maps that to lib/ecs-rails.rb, not lib/ecs_rails.rb, so without
# this file a host Rails app raises LoadError on boot.
#
# The canonical entry point is ecs_rails.rb; this only bridges the naming
# convention. See ADR-0007 for why the gem is "ecs-rails" and the module is
# EcsRails.
require "ecs_rails"
