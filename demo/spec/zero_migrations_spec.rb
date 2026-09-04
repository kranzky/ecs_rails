# frozen_string_literal: true

require "rails_helper"

# The thesis, as a test (ADR-0018): after `rails g ecs_rails:install` and one
# `db:migrate`, this application needed no further migration. Every entity is
# composed from catalogue components, relationships and markers; db/migrate
# holds exactly one file; the seed runs and every page's queries resolve
# against the install schema alone.
RSpec.describe "zero migrations after install" do
  it "has exactly one migration, the install" do
    files = Dir[Rails.root.join("db/migrate/*.rb")].map { |f| File.basename(f) }

    expect(files.size).to eq 1
    expect(files.first).to end_with "_ecs_rails_install.rb"
  end

  it "declares no bespoke component — every component class is a catalogue one-liner" do
    files = Dir[Rails.root.join("app/entities/components/*.rb")] - [Rails.root.join("app/entities/components/application_component.rb").to_s]

    expect(files).not_to be_empty
    files.each do |file|
      expect(File.read(file)).to match(/include EcsRails::Catalogue::\w+/), file
    end
  end

  it "composes every entity from the catalogue" do
    catalogue = EcsRails::Catalogue.components.map(&:class_name)

    [User, Post, Comment, Group, Membership].each do |entity|
      entity.components.each do |component|
        expect(catalogue).to include(component.name), "#{entity}: #{component} is not a catalogue component"
      end
    end
  end

  it "seeds and serves the whole board from the install schema" do
    Demo::Reset.call # truncate, then seed — the test database may hold an earlier seed

    post = Post.published.first
    aggregate_failures do
      expect(post.title).to be_present
      expect(post.author.name.to_s).to be_present
      expect(post.likes).to be >= 0
      expect(Comment.with_related(:post, Post.published.last).count).to be >= 0
      expect(User.with_marker(:moderator).count).to eq 2
      expect(Group.first.rules).to be_present
      expect(Membership.first.role_name).to be_present
      expect(Text.distinct.pluck(:slot).sort).to eq %w[bio body description name rules title]
    end
  end
end
