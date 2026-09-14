# frozen_string_literal: true

require "digest"

module PerformanceComparison
  module Fixtures
    module_function

    def id(kind, number)
      hex = Digest::SHA256.hexdigest("ecs-33:#{kind}:#{number}")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def entity(kind, number)
      { id: id(kind, number), model: kind, created_at: timestamp(number) }
    end

    # Deliberate date ties exercise the final UUID ordering, including at page edges.
    def timestamp(number)
      Time.utc(2026, 1, 1) + number / 100
    end

    def load(size)
      sellers = [size / 20, 1].max
      owners = (0...sellers).map { |i| entity("companies", i) }
      users = (0...20).map { |i| entity("users", i) }
      ApplicationEntity.insert_all!(owners + users)
      Plain::Company.insert_all!(owners.each_with_index.map { |row, i| { id: row[:id], name: "Seller #{i}", email: "seller#{i}@example.test" } })
      Plain::User.insert_all!(users.each_with_index.map { |row, i| { id: row[:id], given: "Reader", family: i.to_s, email: "reader#{i}@example.test" } })
      ::Text.insert_all!(owners.each_with_index.map { |row, i| { entity_id: row[:id], slot: "name", value: "Seller #{i}" } })
      ::Email.insert_all!(owners.each_with_index.map { |row, i| { entity_id: row[:id], slot: "", address: "seller#{i}@example.test" } })
      ::Name.insert_all!(users.each_with_index.map { |row, i| { entity_id: row[:id], slot: "", given: "Reader", family: i.to_s } })
      ::Email.insert_all!(users.each_with_index.map { |row, i| { entity_id: row[:id], slot: "", address: "reader#{i}@example.test" } })

      size.times.each_slice(100) do |indices|
        rows = Hash.new { |hash, key| hash[key] = [] }
        indices.each do |i|
          product_id = id("products", i)
          seller_id = id("companies", i % sellers)
          created_at = timestamp(i)
          amount = i % 13 == 0 ? 0 : 100 + (i % 20) * 100
          status = i % 11 == 0 ? "draft" : "listed"
          tags = [i.even? ? "books" : "hardware"]
          stars = 1 + i % 5
          values = TEXT_SLOTS.to_h { |slot| [slot, slot == "title" ? "Product #{i} common" : "#{slot} common #{i} " * 16] }
          review_count = i == 2 ? 30 : 3
          counters = COUNTER_SLOTS.to_h { |slot| [slot, slot == "stock" ? 10_000 : (slot == "review_count" ? review_count : i % 9)] }
          rows[ApplicationEntity] << entity("products", i)
          rows[Plain::Product] << values.merge(counters).merge(id: product_id, seller_id: seller_id, amount_cents: amount,
                                                             currency: "USD", status: status, tags: tags, stars: stars,
                                                             sku: "SKU-#{i}", created_at: created_at)
          values.each { |slot, value| rows[::Text] << { entity_id: product_id, slot: slot, value: value } }
          counters.each { |slot, count| rows[::Counter] << { entity_id: product_id, slot: slot, count: count } }
          rows[::Money] << { entity_id: product_id, slot: "price", amount_cents: amount, currency: "USD" } unless amount.zero?
          rows[::State] << { entity_id: product_id, slot: "listing", status: status }
          rows[::Rating] << { entity_id: product_id, slot: "", stars: stars }
          rows[::Tags] << { entity_id: product_id, slot: "", names: tags }
          rows[::Identifier] << { entity_id: product_id, slot: "sku", value: "SKU-#{i}" }
          rows[::SearchVector] << { entity_id: product_id, slot: "" }
          rows[::Relationship] << { entity_id: product_id, slot: "seller", target_id: seller_id, owner_model: "products" }
          review_count.times do |review_index|
            n = i * 30 + review_index
            review_id = id("reviews", n)
            author_id = id("users", n % 20)
            rows[ApplicationEntity] << entity("reviews", n)
            rows[Plain::Review] << { id: review_id, product_id: product_id, author_id: author_id, body: "Review #{n}",
                                    stars: 1 + n % 5, likes: n % 4, created_at: timestamp(n) }
            rows[::Text] << { entity_id: review_id, slot: "body", value: "Review #{n}" }
            rows[::Rating] << { entity_id: review_id, slot: "", stars: 1 + n % 5 }
            rows[::Counter] << { entity_id: review_id, slot: "likes", count: n % 4 }
            rows[::Relationship] << { entity_id: review_id, slot: "product", target_id: product_id, owner_model: "reviews" }
            rows[::Relationship] << { entity_id: review_id, slot: "author", target_id: author_id, owner_model: "reviews" }
          end
        end
        # Owners and conventional products precede every referencing row.
        [ApplicationEntity, Plain::Product, Plain::Review].each { |model| model.insert_all!(rows.delete(model)) }
        rows.each { |model, values| model.insert_all!(values) unless values.empty? }
      end
      connection = ActiveRecord::Base.connection
      connection.execute("UPDATE search_vectors SET document = (SELECT to_tsvector('simple', string_agg(value, ' ' ORDER BY slot)) FROM texts WHERE texts.entity_id = search_vectors.entity_id)")
      columns = TEXT_SLOTS.map { |slot| connection.quote_column_name(slot) }.join(", ")
      connection.execute("UPDATE bench_products SET document = to_tsvector('simple', concat_ws(' ', #{columns}))")
      connection.execute("ANALYZE")
    end
  end
end
