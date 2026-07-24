# frozen_string_literal: true

# The gem is published as "ecs_on_rails", but its canonical require path and
# module are "ecs_rails" / EcsRails. Bundler requires a gem by its own name, so
# `Bundler.require` (i.e. a bare `gem "ecs_on_rails"` in a Gemfile) attempts
# `require "ecs_on_rails"` and would raise LoadError without this file.
#
# Requiring "ecs_rails" directly is equivalent and is what the documentation
# uses throughout.
require "ecs_rails"
