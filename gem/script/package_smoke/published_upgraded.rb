# frozen_string_literal: true

# After the 0.3 -> candidate Gemfile change, with no migration: the same rows,
# readable and writable through the candidate package.
raise "Package verification must eager-load at boot" unless Rails.application.config.eager_load
raise "Wrong candidate installation" unless File.realpath(Gem.loaded_specs.fetch("ecs_on_rails").full_gem_path).start_with?(File.realpath(ENV.fetch("ECS_SMOKE_GEM_HOME")) + "/")
raise "Candidate is still 0.3.0" if EcsRails::VERSION == "0.3.0"
raise "Expected one install migration" unless Rails.root.glob("db/migrate/*.rb").size == 1
ids = JSON.parse(File.read(Rails.root.join("tmp/published_ids.json")))
person = Person.find(ids.fetch("person"))
raise "Component data/identity changed" unless person.email.id == ids.fetch("email") && person.email_address == "ada@example.test"
raise "Slot data/identity changed" unless person.mobile_phone.id == ids.fetch("phone") && person.mobile_phone_e164 == "+12025550101"
raise "Relationship target/identity changed" unless person.employer_relationship.id == ids.fetch("employer") && person.employer.name == "Analytical Engines"
raise "Marker presence/identity changed" unless person.admin? && Marker.where(entity_id: person.id, slot: "admin").sole.id == ids.fetch("admin")

# Writes on the candidate: a component loaded on its own updates without
# reading its owner back (ECS-47), and a new entity's rows point at it (ECS-46).
email = Email.find(ids.fetch("email"))
reads = []
counter = ->(*, payload) { reads << payload[:sql] if payload[:sql].include?('FROM "entities"') }
ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { email.update!(verified: true) }
raise "Updating a component read its owner back: #{reads.inspect}" unless reads.empty?
grace = Person.create!(name_given: "Grace", email_address: "grace@example.test")
raise "New entity's component lost its owner" unless grace.email.entity.equal?(grace)
Rails.application.eager_load!
puts "Published 0.3.0 upgrade preserved component, slot, relationship and marker IDs, with no migration."
