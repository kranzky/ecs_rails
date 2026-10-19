# frozen_string_literal: true

require "rails_helper"

# ECS-40: Demo::Checkout reads a basket's products, with their listing, title
# and price, once per basket after the stock lock, instead of once per line.
# These pin that reads no longer grow with the number of lines, and that the
# new read boundary sees the database as it is under the lock rather than as
# the caller's objects remember it. If that regressed, a line could be sold
# from a stale listing or snapshotted at an old price.
RSpec.describe "checkout reads" do
  before(:all) { Demo::Reset.call }

  let(:katherine) { User.with_component(Name, given: "Katherine").first }
  let(:card) { "4242424242424242" }

  def products(count)
    Product.listed.order(:created_at).first(count).each { |product| product.update!(stock: 100) if product.stock < 50 }
  end

  # A basket holding one of each product, starting empty: examples run in any
  # order and share the seeded data.
  def fill(products)
    basket = katherine.basket || katherine.create_basket!
    basket.clear!
    products.each { |product| BasketItem.create!(basket: basket, product: product, quantity: 1) }
    Basket.find(basket.id)
  end

  def reads
    count = 0
    counter = lambda do |*arguments|
      payload = arguments.last
      count += 1 if payload[:sql].lstrip.start_with?("SELECT") && !payload[:cached] && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  it "reads as much for five lines as for one" do
    # Baskets are filled outside the count: setup is not checkout.
    single = fill(products(1))
    one = reads { Demo::Checkout.call(basket: single, card_number: card) }
    multiple = fill(products(5))
    five = reads { Demo::Checkout.call(basket: multiple, card_number: card) }

    expect(five).to eq one
  end

  it "checks the listing as it is under the lock, not as the caller loaded it" do
    product = Product.create!(title: "Brass cog", listing_state_status: "listed", stock: 5, price_money_amount_cents: 300)
    basket = fill([product])
    basket.items.map(&:product).each(&:listed?) # the caller's cache says listed
    Product.find(product.id).delist!

    expect { Demo::Checkout.call(basket: basket, card_number: card) }
      .to raise_error(Demo::Checkout::Error, /Brass cog is no longer listed/)
  end

  it "copies the price as it is under the lock, not as the caller loaded it" do
    product = Product.create!(title: "Steel cam", listing_state_status: "listed", stock: 5, price_money_amount_cents: 300)
    basket = fill([product])
    basket.items.map(&:product).each(&:price_money) # the caller's cache says $3.00
    Product.find(product.id).update!(price_money_amount_cents: 450)

    order = Demo::Checkout.call(basket: basket, card_number: card)

    expect(order.items.sole.unit_price_money.amount_cents).to eq 450
    expect(order.total_money.amount_cents).to eq 450
  end

  it "still refuses a line whose product no longer exists" do
    product = Product.create!(title: "Lost gear", listing_state_status: "listed", stock: 5, price_money_amount_cents: 300)
    basket = fill([product])
    product.destroy!

    expect { Demo::Checkout.call(basket: basket, card_number: card) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
