# frozen_string_literal: true

module Demo
  # The demo's seed data, as a callable module so both `rails db:seed` and the
  # periodic reset (Demo::Reset) use one definition — no top-level method
  # pollution from re-loading db/seeds.rb.
  module Seed
    module_function

    def call
      ada   = user("Ada", "Lovelace", "ada@example.com",
                   bio: "Wrote the first algorithm. Fond of analytical engines.", admin: true, moderator: true)
      grace = user("Grace", "Hopper", "grace@example.com",
                   bio: "Compiler pioneer. Keeps a nanosecond on her desk.", moderator: true)
      alan  = user("Alan", "Turing", "alan@example.com", bio: "Asks whether machines can think.")
      katherine = user("Katherine", "Johnson", "katherine@example.com", bio: "Trajectories to the Moon, by hand.")

      posts = [
        [ada,   "Composable domain models",  "Entities are identity; components carry the state and behaviour. It reads like plain Rails.", "published"],
        [grace, "On lazy components",        "A component costs nothing until a value differs from its default. No row, no query, no ceremony.", "published"],
        [alan,  "Markers without STI",       "A user *is* a moderator exactly when the row exists. Presence is the whole meaning.", "published"],
        [katherine, "Querying by composition", "with_component filters entities by what they're made of, and scopes to the entity type for free.", "published"],
        [grace, "A rough draft",             "Not ready for the world yet — still thinking this one through.", "draft"]
      ]

      created = posts.map do |author, title, body, state|
        post(author, title, body, state)
      end

      [[created[0], grace, "This finally makes the pattern click."],
       [created[0], alan,  "Reuse without inheritance — elegant."],
       [created[1], ada,   "The zero-row default is the best part."]].each do |post, author, text|
        comment(post, author, text)
      end

      rubyists = group("Rubyists", "People who enjoy writing Ruby.")
      pioneers = group("Computing Pioneers", "The people who got us here.")

      [[ada, rubyists, "owner"], [grace, rubyists, "member"], [alan, rubyists, "member"],
       [ada, pioneers, "member"], [grace, pioneers, "member"], [katherine, pioneers, "member"]].each do |u, g, role|
        membership(u, g, role)
      end

      "#{User.count} users, #{Post.count} posts (#{Post.published.count} published), " \
        "#{Comment.count} comments, #{Group.count} groups, #{Membership.count} memberships"
    end

    def user(first, last, email, bio: nil, moderator: false, admin: false)
      u = User.create!
      u.name.first = first
      u.name.last = last
      u.email.address = email
      u.bio.text = bio if bio
      u.save!
      u.add(Moderator) if moderator
      u.add(Administrator) if admin
      u
    end

    def post(author, title, body, state)
      p = Post.create!
      p.title.text = title
      p.body.text = body
      p.author = author
      p.publish_state.state = state
      p.likes.count = rand(0..12)
      p.save!
      p
    end

    def comment(post, author, text)
      c = Comment.create!
      c.body.text = text
      c.author = author
      c.post = post
      c.likes.count = rand(0..5)
      c.save!
      c
    end

    def group(name, description)
      g = Group.create!
      g.name.first = name
      g.description.text = description
      g.save!
      g
    end

    def membership(user, group, role)
      m = Membership.create!
      m.user = user
      m.group = group
      m.role.name = role
      m.save!
      m
    end
  end
end
