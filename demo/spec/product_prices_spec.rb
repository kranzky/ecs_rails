# frozen_string_literal: true

require "rails_helper"

# ECS-27: a missing Money row displays USD 0.00, so catalogue filters and
# ordering must treat it as the same price as a persisted zero. This product
# rule must not change the gem's component-presence query semantics.
RSpec.describe "marketplace displayed prices" do
  let!(:virtual_free) { Product.create!(title: "Virtual free", listing_state_status: "listed") }
  let!(:persisted_free) do
    product = Product.create!(title: "Persisted free", listing_state_status: "listed")
    product.add(Money, prefix: :price)
    product
  end
  let!(:at_ceiling) { Product.create!(title: "At ceiling", listing_state_status: "listed", price_money_amount_cents: 1000) }
  let!(:above_ceiling) { Product.create!(title: "Above ceiling", listing_state_status: "listed", price_money_amount_cents: 1001) }
  let(:products) { Product.where(id: [virtual_free, persisted_free, at_ceiling, above_ceiling].map(&:id)) }

  it "displays the same zero for virtual and persisted free prices" do
    expect(virtual_free.price_money).not_to be_persisted
    expect(persisted_free.price_money).to be_persisted
    expect([virtual_free, persisted_free].map { |product| product.price_money.to_s })
      .to eq ["USD 0.00", "USD 0.00"]
    expect([virtual_free, persisted_free].map { |product| ApplicationController.helpers.price_tag(product.price_money) })
      .to eq ["$0.00", "$0.00"]
  end

  it "includes both free prices and the exact ceiling, excluding the next cent" do
    expect(products.listed.priced_at_most(1000))
      .to contain_exactly(virtual_free, persisted_free, at_ceiling)
  end

  it "includes virtual and persisted zero at a zero ceiling" do
    expect(products.priced_at_most(0)).to contain_exactly(virtual_free, persisted_free)
  end

  it "excludes both zero prices at a negative ceiling" do
    expect(products.priced_at_most(-1)).to be_empty
  end

  it "leaves the current scope unchanged without a ceiling" do
    expect(products.priced_at_most(nil)).to contain_exactly(virtual_free, persisted_free, at_ceiling, above_ceiling)
  end

  %w[price_asc price_desc].each do |sort|
    it "sorts every product by its displayed price for #{sort}" do
      prices = products.sorted(sort).map { |product| product.price_money.amount_cents }
      expected = sort == "price_asc" ? [0, 0, 1000, 1001] : [1001, 1000, 0, 0]

      expect(prices).to eq expected
    end
  end

  it "uses the same tie-breakers for virtual and persisted zero" do
    instant = Time.utc(2026, 9, 12)
    [virtual_free, persisted_free].each { |product| product.update!(created_at: instant) }
    free_ids = [virtual_free.id, persisted_free.id].sort

    expect(products.priced_at_most(0).sorted("price_asc").pluck(:id)).to eq free_ids
    expect(products.priced_at_most(0).sorted("price_desc").pluck(:id)).to eq free_ids
  end

  it "composes price queries with listing and category restrictions without duplicates" do
    virtual_free.update!(tags_names: ["books"])
    persisted_free.update!(tags_names: ["hardware"])
    at_ceiling.update!(tags_names: ["books"])
    draft = Product.create!(title: "Unlisted free book", tags_names: ["books"])
    candidates = Product.where(id: products.ids + [draft.id])

    expect(candidates.listed.in_category("books").priced_at_most(1000).sorted("price_asc"))
      .to eq [virtual_free, at_ceiling]
  end

  it "ignores Money in another slot when finding the displayed price" do
    Money.create!(entity: virtual_free, slot: "other", amount_cents: 50_000)

    expect(products.priced_at_most(0)).to contain_exactly(virtual_free, persisted_free)
    expect(products.sorted("price_asc").map { |product| product.price_money.amount_cents })
      .to eq [0, 0, 1000, 1001]
  end

  it "retains the gem's persisted component-presence semantics" do
    expect(products.with_component(Money, prefix: :price, amount_cents: 0))
      .to contain_exactly(persisted_free)
    expect(products.without_component(Money, prefix: :price)).to contain_exactly(virtual_free)
  end
end
