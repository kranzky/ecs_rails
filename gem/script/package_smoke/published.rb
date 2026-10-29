# frozen_string_literal: true

# The published 0.3.0 baseline for the 0.3 -> candidate upgrade (ECS-43): rows
# written by the release apps run today, whose identities the upgrade must keep.
raise "Wrong published installation" unless File.realpath(Gem.loaded_specs.fetch("ecs_on_rails").full_gem_path).start_with?(File.realpath(ENV.fetch("ECS_SMOKE_GEM_HOME")) + "/")
raise "Published baseline is not 0.3.0" unless EcsRails::VERSION == "0.3.0"
company = Company.create!(name: "Analytical Engines")
person = Person.create!(name_given: "Ada", email_address: "ada@example.test",
                        mobile_phone_e164: "+12025550101", employer: company)
person.add(:admin)
ids = { company: company.id, person: person.id, email: person.email.id,
        phone: person.mobile_phone.id, employer: person.employer_relationship.id,
        admin: Marker.where(entity_id: person.id, slot: "admin").sole.id }
File.write(Rails.root.join("tmp/published_ids.json"), JSON.generate(ids))
puts "Published 0.3.0 persisted component, slot, relationship and marker fixtures."
