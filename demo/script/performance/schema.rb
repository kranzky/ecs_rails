# frozen_string_literal: true

module PerformanceComparison
  module Schema
    module_function

    def create
      connection = ActiveRecord::Base.connection
      connection.create_table(:bench_companies, id: :uuid, default: "gen_random_uuid()") do |t|
        t.string :name
        t.string :email
        t.timestamps
      end
      connection.create_table(:bench_users, id: :uuid, default: "gen_random_uuid()") do |t|
        t.string :given
        t.string :family
        t.string :email
        t.string :avatar_url
        t.timestamps
      end
      connection.create_table(:bench_products, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :seller_id
        TEXT_SLOTS.each { |slot| t.text slot }
        COUNTER_SLOTS.each { |slot| t.integer slot, default: 0, null: false }
        t.integer :amount_cents, default: 0, null: false
        t.string :currency, limit: 3, default: "USD", null: false
        t.integer :stars
        t.string :tags, array: true, default: [], null: false
        t.string :status
        t.string :sku
        t.tsvector :document
        t.timestamps
        t.index :seller_id
        t.index :sku, unique: true, where: "sku IS NOT NULL"
        t.index :tags, using: :gin
        t.index :document, using: :gin
      end
      connection.create_table(:bench_reviews, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :product_id
        t.uuid :author_id
        t.text :body
        t.integer :stars
        t.integer :likes, default: 0, null: false
        t.timestamps
        t.index :product_id
        t.index :author_id
      end
      connection.create_table(:bench_baskets, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :customer_id
        t.integer :revision, default: 0, null: false
        t.timestamps
        t.index :customer_id, unique: true
      end
      connection.create_table(:bench_basket_items, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :basket_id
        t.uuid :product_id
        t.integer :quantity, default: 0, null: false
        t.timestamps
        t.index :basket_id
        t.index :product_id
      end
      connection.create_table(:bench_orders, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :customer_id
        t.string :checkout_request
        t.string :number
        t.integer :total_cents, default: 0, null: false
        t.string :currency, limit: 3, default: "USD", null: false
        t.string :status
        t.jsonb :transitions, default: [], null: false
        %w[shipping billing].each { |prefix| Demo::Checkout::ADDRESS_FIELDS.each { |field| t.string "#{prefix}_#{field}" } }
        t.timestamps
        t.index :customer_id
        t.index :checkout_request, unique: true
        t.index :number, unique: true
      end
      connection.create_table(:bench_order_items, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :order_id
        t.uuid :product_id
        t.text :title
        t.integer :quantity, default: 0, null: false
        t.integer :amount_cents, default: 0, null: false
        t.string :currency, limit: 3, default: "USD", null: false
        t.timestamps
        t.index :order_id
        t.index :product_id
      end
      connection.create_table(:bench_invoices, id: :uuid, default: "gen_random_uuid()") do |t|
        t.uuid :order_id
        t.string :number
        t.integer :total_cents, default: 0, null: false
        t.string :currency, limit: 3, default: "USD", null: false
        t.datetime :issued_at
        Demo::Checkout::ADDRESS_FIELDS.each { |field| t.string "billing_#{field}" }
        t.timestamps
        t.index :order_id, unique: true
        t.index :number, unique: true
      end
      { products: { seller: :companies }, reviews: { product: :products, author: :users },
        baskets: { customer: :users }, basket_items: { basket: :baskets, product: :products },
        orders: { customer: :users }, order_items: { order: :orders, product: :products },
        invoices: { order: :orders } }.each do |table, references|
        references.each do |name, target|
          connection.add_foreign_key("bench_#{table}", "bench_#{target}", column: "#{name}_id", on_delete: :nullify)
        end
      end
    end
  end
end
