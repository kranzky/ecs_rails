# frozen_string_literal: true

# Idempotent-ish demo seed data. Run with bin/rails db:seed.
ada = User.create!
ada.name.first = "Ada"; ada.name.last = "Lovelace"
ada.email.address = "ada@example.com"
ada.save!
ada.add(Moderator)

grace = User.create!
grace.name.first = "Grace"; grace.name.last = "Hopper"
grace.email.address = "grace@example.com"
grace.save!

[
  ["First post", "Hello, components.", "published", ada],
  ["Draft idea", "Not ready yet.", "draft", grace],
  ["Second post", "ECS in Rails is fun.", "published", grace]
].each do |title, body, state, author|
  p = Post.create!
  p.title.text = title
  p.body.text = body
  p.author = author
  p.publish_state.state = state
  p.likes.count = 0
  p.save!
end

puts "Seeded #{User.count} users, #{Post.count} posts (#{Post.published.count} published)."
