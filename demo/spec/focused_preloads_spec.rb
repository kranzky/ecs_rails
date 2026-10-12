# frozen_string_literal: true

require "rails_helper"

# ECS-38: each list page preloads, by association name, the component slots it
# renders and no others. Two things are pinned per page. Twice the rows cost no
# more queries, so every slot the view reads was preloaded (an unpreloaded one
# would query once per row). And the slots a page never shows are not loaded,
# so it does not pay for a body or a counter nobody sees, which is what
# type-wide includes_components did. (A slot the view reads reports loaded
# either way, so only the hidden ones are checked by association.) A record
# without a component still renders its virtual default, because a preload
# that finds no row must leave the reader to build one. If a view starts
# showing another slot, its controller must name it, or the query-count
# example fails.
RSpec.describe "focused preloads", type: :request do
  before do
    host! "localhost"
    ApplicationEntity.delete_all
  end

  # Non-cached, non-schema SELECTs for one request.
  def reads_for(path)
    reads = 0
    counter = lambda do |*arguments|
      payload = arguments.last
      reads += 1 if payload[:sql].lstrip.start_with?("SELECT") && !payload[:cached] && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
    expect(response).to have_http_status(:ok)
    reads
  end

  # The page's records, as the controller handed them to the view.
  def records(ivar)
    controller.instance_variable_get(ivar).to_a.tap { |rows| expect(rows).not_to be_empty }
  end

  def expect_not_loaded(rows, *names)
    rows.each do |row|
      names.each { |name| expect(row.association(name)).not_to be_loaded, "#{row.class}##{name} is not shown" }
    end
  end

  def listed_product(index, seller)
    Product.create!(title: "Gear #{index}", body: "A long description nobody reads on a card.",
                    price_money_amount_cents: 1_500, rating_stars: 4, stock: 3, review_count: 2,
                    tags_names: ["hardware"], listing_state_status: "listed", sku: "G-#{index}", seller: seller)
  end

  describe "the market" do
    let(:seller) { Company.create!(name: "Babbage & Co") }

    it "renders a card without loading the body, SKU or search vector" do
      listed_product(1, seller)
      get products_path
      expect_not_loaded(records(:@products), :body_text, :sku_identifier, :search_vector)
      expect(response.body).to include("Gear 1", "$15.00", "Babbage &amp; Co", "hardware", "3 in stock")
    end

    it "costs the same queries for twice the products" do
      3.times { |index| listed_product(index, Company.create!(name: "Seller #{index}")) }
      fewer = reads_for(products_path)
      3.times { |index| listed_product(index + 3, Company.create!(name: "Seller #{index + 3}")) }
      expect(reads_for(products_path)).to eq fewer
    end

    it "renders a product with only a title from virtual defaults" do
      Product.create!(title: "Bare", listing_state_status: "listed")
      get products_path
      expect(response.body).to include("Bare", "$0.00", "Not yet rated", "Out of stock")
    end
  end

  describe "a product's reviews" do
    let(:product) { listed_product(1, Company.create!(name: "Babbage & Co")) }

    def review(index, **attributes)
      Review.create!(product: product, author: User.create!(name_given: "Reader#{index}"),
                     body: "Review #{index}", rating_stars: 5, likes: 4, **attributes)
    end

    it "renders reviews without loading their likes" do
      review(1)
      get product_path(product)
      expect_not_loaded(records(:@reviews), :likes_counter)
      expect(response.body).to include("Review 1", "Reader1", "★★★★★")
    end

    it "costs the same queries for twice the reviews" do
      2.times { |index| review(index) }
      fewer = reads_for(product_path(product))
      2.times { |index| review(index + 2) }
      expect(reads_for(product_path(product))).to eq fewer
    end

    it "renders a review without a body or rating" do
      review(1, body: nil, rating_stars: nil)
      get product_path(product)
      expect(response.body).to include("Reader1", "Not yet rated")
    end
  end

  describe "a profile's posts" do
    let(:author) { User.create!(name_given: "Grace") }

    def post(index, **attributes)
      Post.create!(author: author, title: "Post #{index}", body: "A body the profile never shows.",
                   publish_state_status: "published", likes: 2, **attributes)
    end

    it "lists posts without loading their bodies" do
      post(1)
      get user_path(author)
      expect_not_loaded(records(:@posts), :body_text, :search_vector)
      expect(response.body).to include("Post 1", "♥ 2")
    end

    it "costs the same queries for twice the posts" do
      2.times { |index| post(index) }
      fewer = reads_for(user_path(author))
      2.times { |index| post(index + 2) }
      expect(reads_for(user_path(author))).to eq fewer
    end

    it "renders an untitled draft with no likes" do
      Post.create!(author: author, body: "Only a body.")
      get user_path(author)
      expect(response.body).to include("Draft", "♥ 0")
    end
  end

  describe "a seller's products" do
    let(:seller) { Company.create!(name: "Babbage & Co") }

    it "lists products without loading body, review count or SKU" do
      listed_product(1, seller)
      get company_path(seller)
      expect_not_loaded(records(:@products), :body_text, :review_count_counter, :sku_identifier)
      expect(response.body).to include("Gear 1", "$15.00", "Listed", "3 in stock")
    end

    it "costs the same queries for twice the products" do
      2.times { |index| listed_product(index, seller) }
      fewer = reads_for(company_path(seller))
      2.times { |index| listed_product(index + 2, seller) }
      expect(reads_for(company_path(seller))).to eq fewer
    end
  end

  describe "the groups list" do
    it "lists groups without loading their rules" do
      Group.create!(name: "Analysts", description: "Engines and notes", rules: "Be kind.")
      get groups_path
      expect_not_loaded(records(:@groups), :rules_text)
      expect(response.body).to include("Analysts", "Engines and notes")
    end

    it "costs the same queries for twice the groups" do
      2.times { |index| Group.create!(name: "Group #{index}", description: "About #{index}") }
      fewer = reads_for(groups_path)
      2.times { |index| Group.create!(name: "Group #{index + 2}") }
      expect(reads_for(groups_path)).to eq fewer
    end
  end

  describe "a customer's orders" do
    let(:customer) { User.create!(name_given: "Ada") }

    def order(index)
      Order.create!(customer: customer, order_number: "ORD-#{index}", checkout_request: "request-#{index}",
                    total_money_amount_cents: 2_500, fulfilment_state_status: "paid")
    end

    it "lists orders without loading the checkout request key" do
      order(1)
      get user_orders_path(customer)
      expect_not_loaded(records(:@orders), :checkout_request_identifier)
      expect(response.body).to include("ORD-1", "$25.00", "Paid")
    end

    it "costs the same queries for twice the orders" do
      2.times { |index| order(index) }
      fewer = reads_for(user_orders_path(customer))
      2.times { |index| order(index + 2) }
      expect(reads_for(user_orders_path(customer))).to eq fewer
    end
  end

  # The address table's owners are of four types, each labelled from a
  # different component. Before ECS-38 every row read its owner's label.
  describe "the geocoder's address table" do
    def owners(index)
      User.create!(name_given: "Person#{index}", shipping_address_locality: "Perth", shipping_address_country: "AU")
      Company.create!(name: "Company #{index}", address_locality: "London", address_country: "GB")
      order = Order.create!(order_number: "ORD-#{index}", shipping_address_locality: "Paris", shipping_address_country: "FR")
      Invoice.create!(order: order, invoice_number: "INV-#{index}", billing_address_locality: "Berlin",
                      billing_address_country: "DE")
    end

    it "labels an owner of each type" do
      owners(1)
      get geocoder_path
      expect(records(:@addresses).map { |address| address.entity.class }).to contain_exactly(User, Company, Order, Invoice)
      expect(response.body).to include("Person1", "Company 1", "Order ORD-1", "Invoice INV-1")
    end

    it "costs the same queries for twice the owners" do
      owners(1)
      fewer = reads_for(geocoder_path)
      owners(2)
      expect(reads_for(geocoder_path)).to eq fewer
    end
  end
end
