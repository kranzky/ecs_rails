# frozen_string_literal: true

raise "Package verification must eager-load at boot" unless Rails.application.config.eager_load
raise "Loaded checkout source instead of installed package" unless File.realpath(Gem.loaded_specs.fetch("ecs_on_rails").full_gem_path).start_with?(File.realpath(ENV.fetch("ECS_SMOKE_GEM_HOME")) + "/")
raise "Unexpected JSON major" unless Gem.loaded_specs.fetch("json").version < Gem::Version.new("3")
raise "Expected one install migration" unless Rails.root.glob("db/migrate/*.rb").size == 1

contact = Contact.create!
raise "Reading inserted a component" if contact.email.persisted?
contact.update!(name_given: "Ada", email_address: "ada@example.test", shipping_address_country: "AU")
contact.featured = true
contact.save!
note = Note.create!(author: contact, body: "Composed without another migration")
raise "Flat assignment lost an email" unless contact.reload.email_address == "ada@example.test"
raise "Labelled slot was lost" unless contact.shipping_address.country == "AU"
raise "Marker query failed" unless Contact.with_marker(:featured).exists?(contact.id)
raise "Relationship query failed" unless Contact.find(contact.id).notes.sole.id == note.id

Rails.application.eager_load!
require "rack/mock"
response = Rack::MockRequest.new(Rails.application).get("/", "HTTP_HOST" => "localhost")
raise "Rendered quickstart failed: #{response.status}" unless response.status == 200 && response.body.include?("Ada: ada@example.test")
puts "Packaged quickstart, components, slots, marker, relationship and rendered page passed."
