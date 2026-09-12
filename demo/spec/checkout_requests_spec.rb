# frozen_string_literal: true

require "rails_helper"

# ECS-28: the rendered form must carry the revision that the POST validates.
# A repeated HTTP submission recovers the same order; edits invalidate stale
# uncompleted forms. This pins controller wiring as well as the system API.
RSpec.describe "checkout submissions", type: :request do
  before { host! "localhost" }

  let(:user) { User.create!(name_given: "Buyer") }
  let(:product) { Product.create!(title: "A product", stock: 5, price_money_amount_cents: 100, listing_state_status: "listed") }
  let(:basket) { Basket.for(user).tap { |basket| basket.add_product!(product, quantity: 1) } }

  def form_params(revision)
    { checkout: { revision: revision, card_number: "4242424242424242", same_billing: "1", shipping: { line1: "1 Main St" } } }
  end

  it "renders a revision and redirects repeated submissions to the original order" do
    revision = basket.revision
    get new_user_checkout_path(user)
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('input[name="checkout[revision]"]')["value"]).to eq revision.to_s

    post user_checkout_path(user), params: form_params(revision)
    expect(response).to have_http_status(:redirect)
    destination = response.location
    order = user.orders.sole
    expect(response).to redirect_to(order_path(order))
    post user_checkout_path(user), params: form_params(revision)
    expect(response.location).to eq destination
    expect(user.orders.count).to eq 1
    expect(product.reload.stock).to eq 4
    expect(order.shipping_address.line1).to eq "1 Main St"
  end

  it "rejects missing and invalid revisions without placing an order" do
    basket
    [nil, "-1", "garbage", "999999999999999999999"].each do |revision|
      post user_checkout_path(user), params: form_params(revision)
      expect(response).to redirect_to(new_user_checkout_path(user))
      expect(flash[:alert]).to include("form is invalid")
    end
    expect(user.orders).to be_empty
    expect(product.reload.stock).to eq 5
  end

  it "invalidates the form through each basket mutation endpoint" do
    revision = basket.revision
    post basket_items_path, params: { basket_item: { user_id: user.id, product_id: product.id, quantity: 1 } }
    expect(basket.reload.revision).to eq revision + 1
    expect(basket.items.sole.quantity).to eq 2
    patch user_basket_item_path(user, basket.items.sole), params: { basket_item: { quantity: 3 } }
    expect(basket.reload.revision).to eq revision + 2
    expect(basket.items.sole.quantity).to eq 3
    post user_checkout_path(user), params: form_params(revision)
    expect(flash[:alert]).to include("basket changed")
    delete user_basket_item_path(user, basket.items.sole)
    expect(basket.reload.revision).to eq revision + 3
    expect(basket.items).to be_empty
    expect(user.orders).to be_empty
  end
end
