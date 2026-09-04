# frozen_string_literal: true

# The one-line application classes `rails g ecs_rails:install` writes, one per
# catalogue component (ADR-0018) — here for the suite. `Relationship` and
# `Marker` are in models.rb, where the core fixtures that depend on them live.
#
# Three catalogue names collide with bespoke fixture classes the core specs are
# built on (Email, Name, Address), so those three take a `Catalogue` prefix AND
# override `table_name` onto a prefixed table — the app-owns-the-table-name
# idiom, proven here to work.
module CatalogueFixtures
  SKIP = %i[relationship marker].freeze
  PREFIXED = %i[email name address].freeze
end

EcsRails::Catalogue.components.each do |mod|
  next if CatalogueFixtures::SKIP.include?(mod.catalogue_name)

  if CatalogueFixtures::PREFIXED.include?(mod.catalogue_name)
    klass = Class.new(ApplicationComponent) do
      include mod
      self.table_name = "catalogue_#{mod.table}"
    end
    Object.const_set(:"Catalogue#{mod.class_name}", klass)
  else
    Object.const_set(mod.class_name, Class.new(ApplicationComponent) { include mod })
  end
end
