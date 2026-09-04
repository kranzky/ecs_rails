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

      marketplace(ada: ada, grace: grace, alan: alan, katherine: katherine)
      commerce(ada: ada, grace: grace, alan: alan)

      Demo::Indexer.call

      "#{User.count} users, #{Post.count} posts (#{Post.published.count} published), " \
        "#{Comment.count} comments, #{Group.count} groups, #{Membership.count} memberships, " \
        "#{Company.count} companies, #{Product.count} products (#{Product.listed.count} listed), " \
        "#{Review.count} reviews, #{Order.count} orders, #{Invoice.count} invoices"
    end

    # The marketplace (ECS-22). Ada owns a company AND reviews products from the
    # others: one User, customer and employee at once.
    def marketplace(ada:, grace:, alan:, katherine:)
      engines = company("Analytical Engines Ltd", "Difference and analytical engines, brass and all.",
                        email: "hello@engines.example", phone: "+442071234567",
                        address: { line1: "1 Marylebone Rd", locality: "London", postcode: "NW1 5LR", country: "GB" })
      nanosecond = company("Nanosecond Supply Co.", "Wire, compilers, and the odd nanosecond.",
                           email: "orders@nanosecond.example", phone: "+12025550147",
                           address: { line1: "900 Broadway", locality: "New York", region: "NY", postcode: "10003", country: "US" })
      press = company("Turing Press", "Books on computation, decidable and otherwise.",
                      email: "editors@turingpress.example",
                      address: { line1: "24 Kings Parade", locality: "Cambridge", postcode: "CB2 1SP", country: "GB" })

      [[ada, engines, "owner"], [grace, engines, "manager"], [alan, engines, "staff"],
       [grace, nanosecond, "owner"], [katherine, nanosecond, "manager"],
       [alan, press, "owner"], [katherine, press, "staff"]].each do |u, c, role|
        Employment.create!(user: u, company: c, role_name: role)
      end

      products = [
        [engines, "Difference Engine No. 2 (kit)", 249_00, "AE-DE2", 3, %w[hardware], "listed",
         "A faithful kit. Some assembly required; a great deal of patience recommended."],
        [engines, "Brass gear set, 40 teeth", 18_50, "AE-G40", 120, %w[hardware], "listed", "Precision cut. Sold as a set of six."],
        [engines, "Punched card pack (500)", 9_00, "AE-PC500", 42, %w[hardware], "listed", "Hollerith-compatible."],
        [engines, "Analytical Engine — full build", 12_000_00, "AE-FULL", 0, %w[hardware], "draft", "Not ready for sale. Still looking for a mill."],
        [nanosecond, "Nanosecond (11.8 inches of wire)", 4_00, "NS-1", 500, %w[hardware], "listed",
         "The distance light travels in a nanosecond. Handy for explaining latency to admirals."],
        [nanosecond, "COBOL compiler, boxed", 89_00, "NS-COBOL", 15, %w[software], "listed", "Runs on most things. Comes with a manual and opinions."],
        [nanosecond, "\"It's easier to ask forgiveness\" tee", 22_00, "NS-TEE", 60, %w[apparel], "listed", "100% cotton."],
        [nanosecond, "Debugging kit (moth included)", 14_00, "NS-MOTH", 0, %w[hardware], "listed", "Currently out of stock. The moth is real."],
        [press, "On Computable Numbers (annotated)", 32_00, "TP-OCN", 25, %w[books], "listed", "The 1936 paper, with margins wide enough to think in."],
        [press, "Computing Machinery and Intelligence", 15_00, "TP-CMI", 40, %w[books], "listed", "Can machines think? A short book about a long question."],
        [press, "Trajectories, by hand", 28_00, "TP-TRAJ", 12, %w[books], "listed", "Orbital mechanics without a computer. Katherine Johnson's method."],
        [press, "Turing Press hoodie", 45_00, "TP-HOOD", 8, %w[apparel books], "delisted", "Discontinued colourway."]
      ]
      created = products.map { |args| product(*args) }

      [[created[0], grace, 5, "Took a month. Worth every gear."],
       [created[0], katherine, 4, "Instructions assume you already own a lathe."],
       [created[1], alan, 5, "Meshes perfectly."],
       [created[4], ada, 5, "I bought twenty. Everyone should have one."],
       [created[4], alan, 4, "Exactly as long as advertised."],
       [created[5], ada, 3, "Verbose."],
       [created[6], katherine, 4, "Fits well."],
       [created[8], ada, 5, "The paper that started it. Beautifully set."],
       [created[8], grace, 5, "Required reading."],
       [created[9], ada, 4, "Short, sharp, still unanswered."],
       [created[10], grace, 5, "She checked the machine's numbers by hand; now you can too."]].each do |product, author, stars, text|
        review(product, author, stars, text)
      end
    end

    # Baskets, checkout and orders (ECS-23). Ada's slots are filled and she has
    # placed an order through the real Checkout system; Alan has a basket.
    def commerce(ada:, grace:, alan:)
      ada.shipping_address.assign_attributes(line1: "12 Ada Lovelace Ln", locality: "Perth", region: "WA", postcode: "6000", country: "AU")
      ada.billing_address.assign_attributes(line1: "PO Box 1815", locality: "Perth", region: "WA", postcode: "6001", country: "AU")
      ada.mobile_phone.e164 = "+61412345678"
      ada.save!
      grace.shipping_address.assign_attributes(line1: "1 Nanosecond Way", locality: "Arlington", region: "VA", postcode: "22201", country: "US")
      grace.work_phone.e164 = "+17035550199"
      grace.save!

      wire  = Product.with_component(Identifier, prefix: :sku, value: "NS-1").first
      paper = Product.with_component(Identifier, prefix: :sku, value: "TP-OCN").first
      gears = Product.with_component(Identifier, prefix: :sku, value: "AE-G40").first

      basket = ada.create_basket!
      BasketItem.create!(basket: basket, product: wire, quantity: 20)
      BasketItem.create!(basket: basket, product: paper, quantity: 1)
      Demo::Checkout.call(basket: basket, card_number: "4242424242424242",
                          shipping: ada.shipping_address.attributes, billing: ada.billing_address.attributes)

      alan_basket = alan.create_basket!
      BasketItem.create!(basket: alan_basket, product: gears, quantity: 2)
    end

    def company(name, description, email:, address:, phone: nil)
      c = Company.create!(name: name, description: description, email_address: email)
      c.phone.e164 = phone if phone
      c.address.assign_attributes(address)
      c.save!
      c
    end

    def product(seller, title, cents, sku, stock, categories, state, body)
      p = Product.new(title: title, body: body, sku: sku, stock: stock, seller: seller, tags_names: categories)
      p.price_money.amount_cents = cents
      p.listing_state.status = state
      p.save!
      p
    end

    def review(product, author, stars, text)
      r = Review.create!(body: text, author: author, product: product, rating_stars: stars, likes: rand(0..4))
      product.recompute_rating!
      r
    end

    # Flat mass assignment through the prefixed delegated writers (ADR-0016):
    # one create! per entity, and only the dirtied components get rows.
    def user(first, last, email, bio: nil, moderator: false, admin: false)
      u = User.create!(name_given: first, name_family: last, email_address: email, bio: bio)
      u.add(:moderator) if moderator
      u.add(:administrator) if admin
      u
    end

    def post(author, title, body, state)
      Post.create!(title: title, body: body, author: author, publish_state_status: state, likes: rand(0..12))
    end

    def comment(post, author, text)
      Comment.create!(body: text, author: author, post: post, likes: rand(0..5))
    end

    # Three Texts under three slots — name, description, rules — one row each
    # in `texts`, through the prefixed delegated writers.
    def group(name, description, rules: nil)
      Group.create!(name: name, description: description, rules: rules)
    end

    def membership(user, group, role)
      Membership.create!(user: user, group: group, role_name: role)
    end
  end
end
