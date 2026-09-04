# frozen_string_literal: true

require "rails_helper"

# The marketplace's first cut (Linear ECS-22): the catalogue pages' filters and
# sort are RFC-0018 in use; authorization is a PORO over the Employment join
# entity; one Role component serves two join entities; a product's rating is
# an aggregate the demo computes itself (the gem has no aggregation primitive).
RSpec.describe "marketplace" do
  before(:all) { Demo::Reset.call }

  describe "catalogue filters (RFC-0018)" do
    it "filters listed products by a price ceiling through a block" do
      cheap = Product.listed.priced_at_most(20_00)

      expect(cheap).not_to be_empty
      expect(cheap.map { |p| p.price_money.amount_cents }).to all(be <= 20_00)
    end

    it "filters by a minimum rating through where-style conditions" do
      good = Product.listed.rated_at_least(4)

      expect(good).not_to be_empty
      expect(good.map(&:rating_stars)).to all(be >= 4)
    end

    it "filters by category through the Tags component's own scope" do
      books = Product.listed.in_category("books")

      expect(books).not_to be_empty
      expect(books).to all(satisfy { |p| p.tags_names.include?("books") })
    end

    it "searches through the SearchVector the entity-blind indexer filled" do
      expect(Product.listed.searching("compiler").map(&:title)).to include("COBOL compiler, boxed")
      expect(Post.published.searching("compiler")).to be_empty
    end

    it "sorts by price and by rating with order_by_component" do
      prices = Product.listed.sorted("price_asc").map { |p| p.price_money.amount_cents }
      expect(prices).to eq prices.sort

      stars = Product.listed.sorted("top_rated").map(&:rating_stars)
      expect(stars.compact).to eq stars.compact.sort.reverse
      expect(stars.last).to be_nil # unrated sorts last
    end

    it "composes every filter and the sort on one entity-scoped query" do
      sql = Product.listed.priced_at_most(50_00).rated_at_least(4).in_category("books").sorted("price_desc").to_sql

      aggregate_failures do
        expect(sql.scan("EXISTS").size).to eq 4
        expect(sql).to include(%("entities"."model" = 'products'))
        expect(sql).to match(/ORDER BY \(SELECT "monies"."amount_cents"/)
      end
    end
  end

  describe "sellers and roles" do
    it "gates product management on the Employment's role" do
      company = Company.with_component(Text, prefix: :name, value: "Analytical Engines Ltd").first
      roles = company.staff.to_h { |e| [e.user.name_given, e.role_name] }
      expect(roles).to eq("Ada" => "owner", "Grace" => "manager", "Alan" => "staff")

      policies = company.staff.to_h { |e| [e.role_name, Demo::CompanyPolicy.new(e.user, company)] }
      aggregate_failures do
        expect(policies["owner"].can?(:manage_products)).to be true
        expect(policies["manager"].can?(:manage_products)).to be true
        expect(policies["staff"].can?(:manage_products)).to be false
        expect(policies["owner"].can?(:manage_employees)).to be true
        expect(policies["manager"].can?(:manage_employees)).to be false
        katherine = User.with_component(Name, given: "Katherine").first
        expect(Demo::CompanyPolicy.new(katherine, company).employee?).to be false
      end
    end

    it "serves Membership and Employment with the one Role component" do
      expect(Role.count).to eq Membership.count + Employment.count
      expect(Employment.first.role_name).to be_present
    end

    it "lets the same user be an employee and a customer" do
      ada = User.with_component(Name, given: "Ada").first

      expect(ada.employments.map { |e| e.company.name }).to include("Analytical Engines Ltd")
      expect(ada.reviews.map { |r| r.product.seller.name }).to include("Nanosecond Supply Co.", "Turing Press")
    end
  end

  describe "reviews" do
    it "recomputes the product's average rating and review count" do
      product = Product.listed.with_component(Identifier, prefix: :sku, value: "AE-DE2").first
      expect(product.rating_stars).to eq 5 # (5 + 4) / 2 rounds up
      expect(product.review_count).to eq 2

      Review.create!(body: "Meh.", author: User.first, product: product, rating_stars: 1)
      product.recompute_rating!

      expect(product.reload.rating_stars).to eq 3
      expect(product.review_count).to eq 3
    end
  end
end
