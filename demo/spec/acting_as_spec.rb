# frozen_string_literal: true

require "rails_helper"

# ECS-35: the demo has no accounts, so a visitor picks who to act as from the
# bar under the navigation. That one choice signs posts, comments and reviews,
# fills the basket and is what the seller policy judges. If it stopped
# persisting, or a form quietly used someone else, the journey would fall
# apart; if it looked like a sign-in, the demo would mislead.
RSpec.describe "acting as", type: :request do
  before(:all) { Demo::Reset.call }

  def person(given) = User.with_component(Name, given: given).first
  def act_as(user) = patch(acting_as_path, params: { user_id: user.id })

  let(:ada) { person("Ada") }
  let(:alan) { person("Alan") }
  let(:grace) { person("Grace") }
  let(:wire) { Product.with_component(Identifier, prefix: :sku, value: "NS-1").first }

  it "defaults to the first person, says it is simulated, and persists a switch" do
    get root_path
    expect(response.body).to include("Acting as", "Simulated: no sign-in")
    expect(response.body).to match(/<option selected="selected" value="#{ada.id}">/)

    act_as(alan)
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(flash[:notice]).to eq "You are now acting as Alan Turing."

    get products_path
    expect(response.body).to match(/<option selected="selected" value="#{alan.id}">/)
    expect(response.body).to include(%(href="/users/#{alan.id}/basket"))
  end

  it "returns to the page the switch was made from" do
    act_as(alan)
    patch acting_as_path, params: { user_id: grace.id }, headers: { "HTTP_REFERER" => product_url(wire) }

    expect(response).to redirect_to(product_url(wire))
  end

  it "signs posts, comments and reviews as the acting user" do
    act_as(alan)

    post posts_path, params: { post: { title: "Acting", body: "As Alan", publish: "1" } }
    created = Post.order(:created_at).last
    expect(created.author).to eq alan

    post post_comments_path(created), params: { comment: { body: "Me again" } }
    expect(created.comments.sole.author).to eq alan

    post product_reviews_path(wire), params: { review: { stars: 4, body: "Long enough" } }
    expect(wire.reviews.order(:created_at).last.author).to eq alan
  end

  it "ignores an author named in the form" do
    act_as(alan)

    post posts_path, params: { post: { title: "Forged", body: "?", publish: "1", author_id: ada.id } }
    expect(Post.order(:created_at).last.author).to eq alan
  end

  it "adds to the acting user's basket" do
    act_as(grace)

    post basket_items_path, params: { basket_item: { product_id: wire.id, quantity: 2 } }
    expect(response).to redirect_to(user_basket_path(grace))
    expect(grace.reload.basket.items.sole.quantity).to eq 2
  end

  it "lets the seller policy judge the acting user, and names who could act instead" do
    act_as(alan) # Alan works at Analytical Engines, not Nanosecond

    get product_path(wire)
    expect(response.body).to include("cannot manage this listing", "Act as Grace Hopper or Katherine Johnson")
    expect(response.body).not_to include(">Delist<")

    patch delist_product_path(wire)
    expect(flash[:alert]).to eq "Alan Turing does not work at Nanosecond Supply Co. " \
                                "Act as Grace Hopper or Katherine Johnson to do this."
    expect(wire.reload).to be_listed

    act_as(grace)
    get product_path(wire)
    expect(response.body).to include("Delist")
    patch delist_product_path(wire)
    expect(wire.reload).to be_delisted
  end

  it "falls back to the first person when the chosen one has gone" do
    stray = User.create!(name_given: "Stray")
    act_as(stray)
    stray.destroy

    get root_path
    expect(response.body).to match(/<option selected="selected" value="#{ada.id}">/)
  end
end
