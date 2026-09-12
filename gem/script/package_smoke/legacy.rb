# frozen_string_literal: true

raise "Wrong legacy installation" unless File.realpath(Gem.loaded_specs.fetch("ecs_on_rails").full_gem_path).start_with?(File.realpath(ENV.fetch("ECS_SMOKE_GEM_HOME")) + "/")
raise "Legacy baseline is not the published API" if defined?(EcsRails::Catalogue)
member = Member.create!
member.handle.value = "Ada"
member.save!
member.add(Moderator)
memo = Memo.new
memo.author = member
memo.save!
ids = { member: member.id, handle: member.handle.id, moderator: member.moderator.id,
        memo: memo.id, relationship: memo.author_relationship.id }
File.write(Rails.root.join("tmp/legacy_ids.json"), JSON.generate(ids))
puts "Published 0.2.2 persisted component, marker and relationship fixtures."
