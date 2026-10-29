# frozen_string_literal: true

require "rails_helper"

# ECS-45: the "How this works" panels beside the product, post, profile and
# order interactions. Three things are pinned. A panel quotes its entity's
# declarations from the class's source file, so it cannot drift from the code.
# Its rows are the ones the page loaded: a stored slot shows its values, a
# loaded empty slot says there is no row, and a slot the page never read says
# that instead. And it never queries for itself. If the panel started fetching
# rows, the last example would fail and every page would pay for an
# explanation most visitors never open. If a view moved its panel above the
# content it explains, the rows that content reads would show as unread.
RSpec.describe "How this works panels", type: :request do
  before(:all) { Demo::Reset.call }
  before { host! "localhost" }

  let(:ada) { User.with_component(Name, given: "Ada").first }
  let(:wire) { Product.with_component(Identifier, prefix: :sku, value: "NS-1").first }

  # The panel's row text, keyed by [table, slot]: "" for the entity's own
  # row, "default slot" or "slot title" for a component's.
  def panel_rows
    panel = Nokogiri::HTML(response.body).at_css("details.how")
    expect(panel).not_to be_nil
    panel.css("tbody tr").to_h do |tr|
      where, row = tr.css("td")
      [[where.at_css(".how__table").text, where.at_css(".how__slot")&.text.to_s.squish], row.text.squish]
    end
  end

  def panel_source
    Nokogiri::HTML(response.body).at_css("details.how pre code").text
  end

  it "quotes the product's declarations from its source file" do
    get product_path(wire)

    declared = File.readlines(Rails.root.join("app/entities/product.rb")).grep(HowThisWorksHelper::DECLARATION)
    expect(response.body).to include("app/entities/product.rb")
    expect(panel_source.lines.map(&:strip)).to eq declared.map(&:strip)
  end

  it "shows the product's stored slots and the one the page never reads" do
    get product_path(wire)
    rows = panel_rows

    aggregate_failures do
      expect(rows[["entities", ""]]).to include("model = products")
      expect(rows[["texts", "slot title"]]).to eq "value = Nanosecond (11.8 inches of wire)"
      expect(rows[["monies", "slot price"]]).to include("amount_cents = 400", "currency = USD")
      expect(rows[["states", "slot listing"]]).to include("status = listed")
      expect(rows[["relationships", "slot seller"]]).to include("owner_model = products")
      expect(rows[[SearchVector.table_name, "default slot"]]).to eq "Not read by this page, so not queried"
    end
  end

  it "shows a post's likes as no row until the first like writes one" do
    post_entity = Post.create!(author: ada, title: "Counting", body: "Nobody has liked this yet.",
                               publish_state_status: "published")

    get post_path(post_entity)
    expect(panel_rows[["counters", "slot likes"]]).to eq "No row: likes_counter reads its column defaults"

    post post_like_path(post_entity)
    get post_path(post_entity)
    expect(panel_rows[["counters", "slot likes"]]).to eq "count = 1"
  end

  it "shows a marker as a row that exists, and the empty slots as no row" do
    grace = User.create!(name_given: "Grace", shipping_address_locality: "Arlington")
    post user_moderator_path(grace)
    get user_path(grace)
    rows = panel_rows

    aggregate_failures do
      expect(rows[["markers", "slot moderator"]]).to eq "A row, with no other columns"
      expect(rows[["markers", "slot administrator"]]).to eq "No row: administrator_marker reads its column defaults"
      expect(rows[["addresses", "slot shipping"]]).to include("locality = Arlington")
      expect(rows[["addresses", "slot billing"]]).to eq "No row: billing_address reads its column defaults"
    end
  end

  it "shows an order's snapshot addresses and leaves its request key unread" do
    get order_path(ada.orders.first)
    rows = panel_rows

    aggregate_failures do
      expect(rows[["addresses", "slot shipping"]]).to include("locality = Perth")
      expect(rows[["addresses", "slot billing"]]).to include("line1 = PO Box 1815")
      expect(rows[["states", "slot fulfilment"]]).to include("status = paid")
      expect(rows[["identifiers", "slot checkout_request"]]).to eq "Not read by this page, so not queried"
    end
  end

  it "renders without a query of its own" do
    product = Product.find(wire.id)
    statements = []
    collect = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }

    html = ActiveSupport::Notifications.subscribed(collect, "sql.active_record") do
      ApplicationController.render(inline: <<~ERB, locals: { product: product })
        <%= render layout: "shared/how_this_works", locals: { entity: product } do %>Explained.<% end %>
      ERB
    end

    expect(statements).to be_empty
    expect(html).to include("Explained.", "Not read by this page")
    expect(html).not_to include("No row:")
  end
end
