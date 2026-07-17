# frozen_string_literal: true

require_relative "generator_helper"

# The other generator specs load the generator classes directly, which would
# still pass if the file layout were wrong. `rails g rorecs:install` only works
# because Rails maps the namespace onto lib/generators/rorecs/<name>/
# <name>_generator.rb. These examples pin that mapping.
RSpec.describe "generator discovery" do
  it "resolves rorecs:install" do
    expect(Rails::Generators.find_by_namespace("install", "rorecs"))
      .to eq(Rorecs::Generators::InstallGenerator)
  end

  it "resolves rorecs:component" do
    expect(Rails::Generators.find_by_namespace("component", "rorecs"))
      .to eq(Rorecs::Generators::ComponentGenerator)
  end
end
