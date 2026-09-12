# frozen_string_literal: true

require "rails_helper"

# ECS-31: page boundaries must remain stable across tied component values and
# preserve the visitor's filters. More off-page data must not allocate or render
# more products, component rows or seller targets for the requested page.
RSpec.describe "demo list pagination", type: :request do
  before do
    host! "localhost"
    ApplicationEntity.delete_all
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def product_ids
    document.css(".product-card h2 a").map { |link| link["href"].split("/").last }
  end

  def create_products(count, **attributes)
    Array.new(count) do |index|
      Product.create!(title: "Book #{index}", listing_state_status: "listed",
                      created_at: Time.utc(2026, 1, 1), **attributes)
    end
  end

  context "market" do
    let!(:products) { create_products(49, price_money_amount_cents: 500, rating_stars: 4, tags_names: ["books"]) }

    %w[newest price_asc price_desc top_rated].each do |sort|
      it "visits each tied #{sort} result once across page boundaries" do
        expected = products.map(&:id).sort
        seen = []
        [24, 24, 1].each_with_index do |size, index|
          get products_path, params: { sort: sort, page: index + 1 }
          expect(response).to have_http_status(:ok)
          expect(product_ids.size).to eq size
          seen.concat(product_ids)
        end
        expect(seen).to eq expected
        expect(document.at_css('.pagination a[rel="next"]')).to be_nil
      end
    end

    it "normalizes malformed pages and clamps pages beyond the last result" do
      first_ids = products.map(&:id).sort.first(24)
      [nil, "0", "-1", "2oops", "1.5", "999999999999999999999", ["2"], { n: "2" }].each do |page|
        get products_path, params: { page: page }
        expect(response).to have_http_status(:ok)
        expect(product_ids).to eq first_ids
      end
      get products_path, params: { page: "999999999" }
      expect(product_ids).to eq [products.map(&:id).max]
    end

    it "preserves every filter and the sort when following navigation" do
      products.each { |product| product.search_vector.reindex!(product.title, "") }
      filters = { q: "Book", max_price: "10", min_stars: "4", category: "books", sort: "price_asc" }
      get products_path, params: filters
      link = document.at_css('.pagination a[rel="next"]')
      expect(link).to be_present
      expect(Rack::Utils.parse_nested_query(URI.parse(link["href"]).query)).to include(filters.stringify_keys.merge("page" => "2"))
      get link["href"]
      expect(product_ids).to eq products.map(&:id).sort.slice(24, 24)
    end

    it "renders an empty result without pagination or stale counts" do
      get products_path, params: { category: "hardware", page: "4" }
      expect(response).to have_http_status(:ok)
      expect(product_ids).to be_empty
      expect(response.body).to include("Nothing matches those filters.")
      expect(document.at_css(".pagination")).to be_nil
    end

    it "loads only the requested products and their preloaded seller/component rows" do
      products.each_with_index { |product, index| product.update!(seller: Company.create!(name: "Seller #{index}")) }
      counts_for_page = lambda do
        counts = Hash.new(0)
        subscriber = ->(*args) { payload = args.last; counts[payload[:class_name]] += payload[:record_count] }
        ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") { get products_path }
        expect(product_ids.size).to eq 24
        counts
      end
      before = counts_for_page.call
      create_products(49, created_at: Time.utc(2025, 1, 1)).each_with_index do |product, index|
        product.update!(seller: Company.create!(name: "Off-page seller #{index}"))
      end
      after = counts_for_page.call
      expect(after).to eq before
      expect(after.fetch("Product")).to eq 24
      expect(after.fetch("Text")).to eq 48
      expect(after.fetch("Relationship")).to eq 24
      expect(after.values.sum).to be < 250
    end
  end

  it "has no next link at an exact page boundary" do
    create_products(24)
    get products_path
    expect(product_ids.size).to eq 24
    expect(document.at_css('.pagination a[rel="next"]')).to be_nil
  end

  [Company, User, Group].each do |model|
    it "bounds #{model.model_name.human.downcase} cards with stable creation-date ties" do
      records = Array.new(25) { model.create!(created_at: Time.utc(2026, 1, 1)) }
      path = polymorphic_path(model)
      get path
      links = document.css("main .grid > a.card")
      expect(links.map { |link| link["href"].split("/").last }).to eq records.map(&:id).sort.first(24)
      get path, params: { page: 2 }
      expect(document.css("main .grid > a.card").size).to eq 1
    end
  end

  %w[newest likes].each do |sort|
    it "bounds tied bulletin #{sort} results and retains search navigation" do
      author = User.create!(name_given: "Author")
      posts = Array.new(25) do |index|
        Post.create!(title: "Bounded post #{index}", body: "Body", author: author,
                     publish_state_status: "published", likes: 3, created_at: Time.utc(2026, 1, 1))
      end
      posts.each { |post| post.search_vector.reindex!(post.title, post.body) }
      get posts_path, params: { q: "Bounded", sort: sort }
      links = document.css(".post-card > a")
      expect(links.map { |link| link["href"].split("/").last }).to eq posts.map(&:id).sort.first(24)
      next_link = document.at_css('.pagination a[rel="next"]')
      expect(Rack::Utils.parse_nested_query(URI.parse(next_link["href"]).query)).to include("q" => "Bounded", "sort" => sort)
      get next_link["href"]
      expect(document.css(".post-card").size).to eq 1
      expect(document.at_css('.pagination [aria-current="page"]').text).to eq "2"
    end
  end

  it "pages a seller's products and staff independently while retaining totals" do
    company = Company.create!(name: "Seller")
    create_products(25, seller: company)
    25.times do |index|
      Employment.create!(company: company, user: User.create!(name_given: "Person #{index}"), role_name: "staff")
    end
    get company_path(company), params: { page: 2 }
    expect(document.css("main .comment").size).to eq 24
    expect(document.css("main a.card-link").size).to eq 1
    expect(document.css("h2").map(&:text)).to include("People · 25", "Products · 25")
    next_staff = document.css('.pagination a[rel="next"]').find { |link| link["href"].include?("staff_page=2") }
    expect(next_staff).to be_present
    expect(Rack::Utils.parse_nested_query(URI.parse(next_staff["href"]).query)).to include("page" => "2", "staff_page" => "2")
    get next_staff["href"]
    expect(document.css("main .comment").size).to eq 1
    expect(document.css("main a.card-link").size).to eq 1
  end

  it "pages a person's posts without changing the total heading" do
    user = User.create!(name_given: "Writer")
    25.times { |index| Post.create!(title: "Post #{index}", author: user) }
    get user_path(user), params: { page: 2 }
    expect(response).to have_http_status(:ok)
    expect(document.css("main a.card-link").size).to eq 1
    expect(document.css("h2").map(&:text)).to include("Posts by Writer · 25")
    expect(document.at_css(".pagination")).to be_present
  end

  it "pages group members even when the group has no house rules" do
    group = Group.create!(name: "Group")
    user = User.create!(name_given: "Member")
    25.times { Membership.create!(group: group, user: user, role_name: "member") }
    get group_path(group)
    expect(document.css("main .comment").size).to eq 24
    next_link = document.at_css('.pagination a[rel="next"]')
    expect(next_link).to be_present
    get next_link["href"]
    expect(document.css("main .comment").size).to eq 1
    expect(document.css("h2").map(&:text)).to include("Members · 25")
  end

  it "pages reviews while retaining the product's full review count" do
    product = Product.create!(title: "Reviewed")
    author = User.create!(name_given: "Reviewer")
    25.times { |index| Review.create!(product: product, author: author, body: "Review #{index}", rating_stars: 4) }
    get product_path(product), params: { page: 2 }
    expect(document.css("main .comment").size).to eq 1
    expect(document.css("h2").map(&:text)).to include("Reviews · 25")
    expect(document.at_css(".pagination")).to be_present
  end

  it "pages comments while retaining the full comment count" do
    post = Post.create!(title: "Discussed", publish_state_status: "published")
    author = User.create!(name_given: "Commenter")
    25.times { |index| Comment.create!(post: post, author: author, body: "Comment #{index}") }
    get post_path(post), params: { page: 2 }
    expect(document.css("main .comment").size).to eq 1
    expect(document.css("h2").map(&:text)).to include("Comments · 25")
    expect(document.at_css(".pagination")).to be_present
  end

  it "bounds a customer's order history" do
    user = User.create!(name_given: "Buyer")
    25.times { |index| Order.create!(customer: user, order_number: "Pagination-#{index}") }
    get user_orders_path(user)
    expect(document.css("main a.card-link").size).to eq 24
    get document.at_css('.pagination a[rel="next"]')["href"]
    expect(document.css("main a.card-link").size).to eq 1
  end
end
