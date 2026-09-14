# frozen_string_literal: true

raise "Entity ignored configured path" unless Rails.root.join("app/models/crm/person.rb").file?
raise "Entity generated outside configured path" if Rails.root.join("app/entities").exist?
raise "Entity generator added storage" unless Rails.root.glob("db/migrate/*.rb").size == 1
person = Crm::Person.create!(name_given: "Ada", work_business_contact_email_address: "ada@example.test", home_address_country: "AU")
raise "Namespaced component did not persist" unless person.reload.work_business_contact_email.address == "ada@example.test"
raise "Top-level component in namespace failed" unless person.name_given == "Ada" && person.home_address.country == "AU"
puts "Configured entity/component paths and namespaced references passed."
