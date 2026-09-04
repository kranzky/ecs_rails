# frozen_string_literal: true

require "rails_helper"

# The marketplace's second cut (Linear ECS-23): the Checkout system over
# components — copies not links, Money arithmetic, the State transition, the
# has_one invoice, sequential numbers — and its rollback on a declined card.
# If Checkout stopped snapshotting prices, an old order would change when a
# product was repriced; if the transaction stopped rolling back, a declined
# card would leave a paid-looking order.
RSpec.describe "checkout" do
  before(:all) { Demo::Reset.call }

  let(:ada)  { User.with_component(Name, given: "Ada").first }
  let(:alan) { User.with_component(Name, given: "Alan").first }
  let(:wire) { Product.with_component(Identifier, prefix: :sku, value: "NS-1").first }

  # A basket holding exactly these lines — examples run in any order, so each
  # starts from an empty basket rather than trusting the last one's ending.
  def fill(user, *products)
    basket = user.basket || user.create_basket!
    basket.clear!
    products.each { |product, qty| BasketItem.create!(basket: basket, product: product, quantity: qty) }
    basket
  end

  it "places a paid order with an invoice from the seeded basket" do
    order = ada.orders.first

    aggregate_failures do
      expect(order.order_number).to eq "ORD-000001"
      expect(order.status).to eq "paid"
      expect(order.items.size).to eq 2
      expect(order.total_money.amount_cents).to eq 20 * 4_00 + 32_00
      expect(order.shipping_address.locality).to eq "Perth"
      expect(order.billing_address.line1).to eq "PO Box 1815"
      expect(order.invoice.invoice_number).to eq "INV-000001"
      expect(order.invoice.total_money.amount_cents).to eq order.total_money.amount_cents
      expect(order.invoice.issued_at).to be_present
      expect(order.fulfilment_state.transitions.last["to"]).to eq "paid"
      expect(ada.basket.items).to be_empty
    end
  end

  it "snapshots the unit price and title, so a later price change leaves the order alone" do
    line = ada.orders.first.items.with_related(:product, wire).first
    wire.price_money.amount_cents = 9_99
    wire.title = "Nanosecond (renamed)"
    wire.save!

    aggregate_failures do
      expect(line.reload.unit_price_money.amount_cents).to eq 4_00
      expect(line.title).to eq "Nanosecond (11.8 inches of wire)"
      expect(line.product.title).to eq "Nanosecond (renamed)"
    end
  ensure
    wire.price_money.amount_cents = 4_00
    wire.title = "Nanosecond (11.8 inches of wire)"
    wire.save!
  end

  it "takes stock and numbers documents sequentially" do
    before = wire.stock
    basket = fill(alan, [wire, 3])
    order = Demo::Checkout.call(basket: basket, card_number: "4242 4242 4242 4242", shipping: { line1: "x" })

    aggregate_failures do
      expect(wire.reload.stock).to eq before - 3
      expect(order.order_number).to eq "ORD-000002"
      expect(order.invoice.invoice_number).to eq "INV-000002"
      expect(alan.orders.size).to eq 1
    end
  end

  it "rolls everything back when the card is declined" do
    before = wire.stock
    basket = fill(alan, [wire, 2])
    orders = Order.count

    expect {
      Demo::Checkout.call(basket: basket, card_number: Demo::PaymentGateway::DECLINED)
    }.to raise_error(Demo::Checkout::Error, /declined/)

    aggregate_failures do
      expect(Order.count).to eq orders
      expect(Invoice.count).to eq orders
      expect(wire.reload.stock).to eq before
      expect(basket.items.size).to eq 1
    end
  end

  it "refuses an empty basket and more than the stock" do
    expect { Demo::Checkout.call(basket: fill(alan), card_number: "4242424242424242") }
      .to raise_error(Demo::Checkout::Error, /empty/)

    basket = fill(alan, [wire, 10_000])
    expect { Demo::Checkout.call(basket: basket, card_number: "4242424242424242") }
      .to raise_error(Demo::Checkout::Error, /in stock/)
  end

  it "keeps two Address slots and two Phone slots apart on one user" do
    aggregate_failures do
      expect(ada.shipping_address.postcode).to eq "6000"
      expect(ada.billing_address.postcode).to eq "6001"
      expect(ada.mobile_phone.e164).to eq "+61412345678"
      expect(ada.work_phone.e164).to be_nil
      expect(Address.where(entity_id: ada.id).pluck(:slot).sort).to eq %w[billing shipping]
      expect(Phone.where(entity_id: ada.id).pluck(:slot)).to eq %w[mobile]
    end
  end
end
