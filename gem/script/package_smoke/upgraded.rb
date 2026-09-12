# frozen_string_literal: true

raise "Wrong candidate installation" unless File.realpath(Gem.loaded_specs.fetch("ecs_on_rails").full_gem_path).start_with?(File.realpath(ENV.fetch("ECS_SMOKE_GEM_HOME")) + "/")
ids = JSON.parse(File.read(Rails.root.join("tmp/legacy_ids.json")))
member = Member.find(ids.fetch("member"))
memo = Memo.find(ids.fetch("memo"))
raise "Component data/identity changed" unless member.handle.id == ids.fetch("handle") && member.handle.value == "Ada" && member.handle.slot == ""
raise "Marker presence lost" unless member.moderator?
raise "Marker identity changed" unless Marker.where(entity_id: member.id, slot: "moderator").sole.id == ids.fetch("moderator")
raise "Relationship target/identity changed" unless memo.author_id == member.id && memo.author_relationship.id == ids.fetch("relationship")
raise "Old relationship table remains" if ActiveRecord::Base.connection.table_exists?(:memo_authors)
raise "Old marker table remains" if ActiveRecord::Base.connection.table_exists?(:moderators)
raise "No structural inspector in package" unless defined?(EcsRails::Catalogue::SchemaDiff)
Rails.application.eager_load!
puts "Published 0.2.2 upgrade preserved component, marker, relationship and entity IDs."
