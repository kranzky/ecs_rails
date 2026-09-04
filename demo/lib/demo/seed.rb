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

      rubyists = group("Rubyists", "People who enjoy writing Ruby.",
                       rules: "Be kind. Share code, not screenshots. No language wars.")
      pioneers = group("Computing Pioneers", "The people who got us here.")

      [[ada, rubyists, "owner"], [grace, rubyists, "member"], [alan, rubyists, "member"],
       [ada, pioneers, "member"], [grace, pioneers, "member"], [katherine, pioneers, "member"]].each do |u, g, role|
        membership(u, g, role)
      end

      "#{User.count} users, #{Post.count} posts (#{Post.published.count} published), " \
        "#{Comment.count} comments, #{Group.count} groups, #{Membership.count} memberships"
    end

    # Flat mass assignment through the prefixed delegated writers (ADR-0016):
    # one create! per entity, and only the dirtied components get rows.
    def user(first, last, email, bio: nil, moderator: false, admin: false)
      u = User.create!(name_first: first, name_last: last, email_address: email, bio_text: bio)
      u.add(Moderator) if moderator
      u.add(Administrator) if admin
      u
    end

    def post(author, title, body, state)
      Post.create!(title_text: title, body_text: body, author: author, state: state, likes_count: rand(0..12))
    end

    def comment(post, author, text)
      Comment.create!(body_text: text, author: author, post: post, likes_count: rand(0..5))
    end

    # `rules:` lands in the :rules slot of Description (RFC-0014) — same
    # component, second row — through the prefixed delegated writer.
    def group(name, description, rules: nil)
      Group.create!(name_first: name, description_text: description, rules_description_text: rules)
    end

    def membership(user, group, role)
      Membership.create!(user: user, group: group, role_name: role)
    end
  end
end
