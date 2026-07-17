# frozen_string_literal: true

require_relative "generator_helper"

# The other generator specs load the generator classes directly, which would
# still pass if the file layout were wrong. `rails g ecs_rails:install` only works
# because Rails maps the namespace onto lib/generators/ecs_rails/<name>/
# <name>_generator.rb. These examples pin that mapping.
RSpec.describe "generator discovery" do
  it "resolves ecs_rails:install" do
    expect(Rails::Generators.find_by_namespace("install", "ecs_rails"))
      .to eq(EcsRails::Generators::InstallGenerator)
  end

  it "resolves ecs_rails:component" do
    expect(Rails::Generators.find_by_namespace("component", "ecs_rails"))
      .to eq(EcsRails::Generators::ComponentGenerator)
  end
end
