# frozen_string_literal: true

require "rails_helper"
require "timeout"

# ECS-28: committed fixtures and separate PostgreSQL connections expose races
# hidden by transactional examples. Queues hold the first checkout at payment;
# pg_blocking_pids proves the other transaction is actually waiting before it
# is released. No timing sleeps decide which request wins.
RSpec.describe "concurrent checkout" do
  self.use_transactional_tests = false

  before do
    @existing_ids = ApplicationEntity.pluck(:id)
    @workers = []
    @release = Queue.new
  end

  after do
    @release << true
    @workers.each { |thread| thread.join(10) || thread.kill }
    ApplicationEntity.where.not(id: @existing_ids).delete_all
  end

  def product(stock: 1)
    Product.create!(title: "Concurrent product", price_money_amount_cents: 100,
                    stock: stock, listing_state_status: "listed")
  end

  def basket_for(product)
    basket = Basket.create!(customer: User.create!)
    BasketItem.create!(basket: basket, product: product, quantity: 1)
    basket
  end

  def worker(&block)
    started = Queue.new
    thread = Thread.new do
      ApplicationEntity.connection_pool.with_connection do |connection|
        started << connection.select_value("SELECT pg_backend_pid()")
        block.call
      rescue StandardError => error
        error
      end
    end
    @workers << thread
    [thread, Timeout.timeout(10) { started.pop }]
  end

  def wait_until_blocked(pid)
    Timeout.timeout(10) do
      loop do
        break if ApplicationEntity.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)})) > 0")
        Thread.pass
      end
    end
  end

  def overlapping_checkouts(first_basket, second_basket, first_card: "4242424242424242", **options)
    charging = Queue.new
    first_charge = true
    allow(Demo::PaymentGateway).to receive(:charge!).and_wrap_original do |method, *args, **kwargs|
      if first_charge
        first_charge = false
        charging << true
        Timeout.timeout(10) { @release.pop }
      end
      method.call(*args, **kwargs)
    end
    first, = worker { Demo::Checkout.call(basket: Basket.find(first_basket.id), card_number: first_card, **options) }
    Timeout.timeout(10) { charging.pop }
    second, pid = worker { Demo::Checkout.call(basket: Basket.find(second_basket.id), card_number: "4242424242424242", **options) }
    wait_until_blocked(pid)
    @release << true
    Timeout.timeout(10) { [first.value, second.value] }
  end

  it "allocates distinct sequential documents to buyers of different products" do
    results = overlapping_checkouts(basket_for(product), basket_for(product))
    expect(results).to all(be_a(Order))
    expect(results.map(&:order_number).uniq.size).to eq 2
    expect(results.map { |order| order.invoice.invoice_number }.uniq.size).to eq 2
  end

  it "sells the last unit only once to competing buyers" do
    item = product
    baskets = [basket_for(item), basket_for(item)]
    results = overlapping_checkouts(*baskets)
    expect(results.first).to be_a(Order)
    expect(results.last).to be_a(Demo::Checkout::Error)
    expect(results.last.message).to include("in stock")
    expect(item.reload.stock).to eq 0
    expect(baskets.last.items.count).to eq 1
  end

  it "returns one order and charges once for two submissions of one basket revision" do
    item = product(stock: 3)
    basket = basket_for(item)
    results = overlapping_checkouts(basket, basket, revision: basket.revision)
    expect(results).to all(be_a(Order))
    expect(results.map(&:id).uniq.size).to eq 1
    expect(item.reload.stock).to eq 2
    expect(basket.reload.items).to be_empty
    expect(Demo::PaymentGateway).to have_received(:charge!).once
  end

  it "rolls back a decline before a waiting retry uses the same revision" do
    item = product
    basket = basket_for(item)
    revision = basket.revision
    results = overlapping_checkouts(basket, basket, revision: revision,
                                   first_card: Demo::PaymentGateway::DECLINED)
    expect(results.first).to be_a(Demo::Checkout::Error)
    expect(results.first.message).to include("declined")
    expect(results.last).to be_a(Order)
    expect(basket.customer.orders.count).to eq 1
    expect(results.last.invoice).to be_present
    expect(item.reload.stock).to eq 0
    expect(basket.reload.revision).to eq revision + 1
  end

  it "reads stock after a competing Counter update commits" do
    item = product
    basket = basket_for(item)
    changed = Queue.new
    holder, = worker do
      Counter.transaction do
        Counter.where(entity_id: item.id, slot: "stock").lock.first.update!(count: 0)
        changed << true
        Timeout.timeout(10) { @release.pop }
      end
    end
    Timeout.timeout(10) { changed.pop }
    checkout, pid = worker { Demo::Checkout.call(basket: basket, card_number: "4242424242424242") }
    wait_until_blocked(pid)
    @release << true
    Timeout.timeout(10) { holder.value }
    result = Timeout.timeout(10) { checkout.value }
    expect(result).to be_a(Demo::Checkout::Error)
    expect(result.message).to include("in stock")
    expect(item.reload.stock).to eq 0
    expect(basket.customer.orders).to be_empty
  end

  it "keeps an addition waiting until checkout clears the purchased contents" do
    item = product(stock: 3)
    basket = basket_for(item)
    charging = Queue.new
    allow(Demo::PaymentGateway).to receive(:charge!).and_wrap_original do |method, *args, **kwargs|
      charging << true
      Timeout.timeout(10) { @release.pop }
      method.call(*args, **kwargs)
    end
    checkout, = worker { Demo::Checkout.call(basket: basket, card_number: "4242424242424242") }
    Timeout.timeout(10) { charging.pop }
    addition, pid = worker { Basket.find(basket.id).add_product!(item, quantity: 2) }
    wait_until_blocked(pid)
    @release << true
    order, added = Timeout.timeout(10) { [checkout.value, addition.value] }
    expect(order).to be_a(Order)
    expect(added).to be_a(BasketItem)
    expect(order.items.first.quantity).to eq 1
    expect(basket.reload.items.first.quantity).to eq 2
    expect(item.reload.stock).to eq 2
  end

  it "rejects a stale form after an edit and replays an earlier success after refilling" do
    item = product(stock: 5)
    basket = basket_for(item)
    revision = basket.revision
    basket.update_item!(basket.items.first.id, quantity: 2)
    expect { Demo::Checkout.call(basket: basket, revision: revision, card_number: "4242424242424242") }
      .to raise_error(Demo::Checkout::Error, /basket changed/)

    revision = basket.revision
    order = Demo::Checkout.call(basket: basket, revision: revision, card_number: "4242424242424242")
    basket.add_product!(item, quantity: 1)
    replay = Demo::Checkout.call(basket: basket, revision: revision, card_number: Demo::PaymentGateway::DECLINED)
    expect(replay.id).to eq order.id
    expect(basket.items.first.quantity).to eq 1
    expect(item.reload.stock).to eq 3
    next_order = Demo::Checkout.call(basket: basket, revision: basket.revision, card_number: "4242424242424242")
    expect(next_order.id).not_to eq order.id
    expect(item.reload.stock).to eq 2
  end

  it "does not consume missing stock or a nonpositive quantity" do
    item = product(stock: 0)
    basket = basket_for(item)
    expect(Counter.where(entity_id: item.id, slot: "stock")).not_to exist
    expect { Demo::Checkout.call(basket: basket, card_number: "4242424242424242") }
      .to raise_error(Demo::Checkout::Error, /in stock/)
    basket.update_item!(basket.items.first.id, quantity: 0)
    expect { Demo::Checkout.call(basket: basket, card_number: "4242424242424242") }
      .to raise_error(Demo::Checkout::Error, /quantity must be positive/)
  end

  it "allocates numeric document suffixes beyond six digits" do
    owner = User.create!
    Identifier.create!(entity: owner, slot: "order_number", value: "ORD-999999")
    ApplicationEntity.transaction do
      expect(Demo::Numbering.next("order_number", "ORD")).to eq "ORD-1000000"
      Identifier.create!(entity: User.create!, slot: "order_number", value: "ORD-1000000")
      expect(Demo::Numbering.next("order_number", "ORD")).to eq "ORD-1000001"
    end
    expect { Demo::Numbering.next("order_number", "ORD") }.to raise_error(ArgumentError, /transaction/)
  end

  it "coordinates invoice numbering even outside checkout" do
    allocated = Queue.new
    first, = worker do
      Invoice.transaction do
        number = Invoice.next_number
        Identifier.create!(entity: User.create!, slot: "invoice_number", value: number)
        allocated << number
        Timeout.timeout(10) { @release.pop }
        number
      end
    end
    number = Timeout.timeout(10) { allocated.pop }
    second, pid = worker do
      Invoice.transaction do
        next_number = Invoice.next_number
        Identifier.create!(entity: User.create!, slot: "invoice_number", value: next_number)
        next_number
      end
    end
    wait_until_blocked(pid)
    @release << true
    results = Timeout.timeout(10) { [first.value, second.value] }
    expect(results).to eq [number, format("INV-%06d", number.delete("^0-9").to_i + 1)]
  end


  it "reads basket contents after a waiting edit commits and rejects its stale form" do
    item = product(stock: 5)
    basket = basket_for(item)
    revision = basket.revision
    edited = Queue.new
    editor, = worker do
      Basket.find(basket.id).mutate! do
        BasketItem.with_related(:basket, basket).first.update!(quantity: 3)
        edited << true
        Timeout.timeout(10) { @release.pop }
      end
    end
    Timeout.timeout(10) { edited.pop }
    checkout, pid = worker do
      Demo::Checkout.call(basket: Basket.find(basket.id), revision: revision, card_number: "4242424242424242")
    end
    wait_until_blocked(pid)
    @release << true
    edit_result, result = Timeout.timeout(10) { [editor.value, checkout.value] }
    expect(edit_result).to eq true
    expect(result).to be_a(Demo::Checkout::Error)
    expect(result.message).to include("basket changed")
    order = Demo::Checkout.call(basket: basket.reload, card_number: "4242424242424242")
    expect(order.items.first.quantity).to eq 3
  end

  it "serializes first additions through the customer's singleton basket" do
    user = User.create!
    item = product(stock: 5)
    locked = Queue.new
    first, = worker do
      User.find(user.id).with_lock do
        locked << true
        Timeout.timeout(10) { @release.pop }
        Basket.for(User.find(user.id)).add_product!(item, quantity: 1)
      end
    end
    Timeout.timeout(10) { locked.pop }
    second, pid = worker { Basket.for(User.find(user.id)).add_product!(item, quantity: 2) }
    wait_until_blocked(pid)
    @release << true
    results = Timeout.timeout(10) { [first.value, second.value] }
    expect(results).to all(be_a(BasketItem))
    expect(Basket.with_related(:customer, user).count).to eq 1
    expect(user.reload.basket.items.count).to eq 1
    expect(user.basket.items.first.quantity).to eq 3
  end

  it "locks overlapping product sets consistently even in opposite basket order" do
    first_product = product(stock: 2)
    second_product = product(stock: 2)
    first = basket_for(first_product)
    second = basket_for(second_product)
    first.add_product!(second_product, quantity: 1)
    second.add_product!(first_product, quantity: 1)
    results = overlapping_checkouts(first, second)
    expect(results).to all(be_a(Order))
    expect([first_product.reload.stock, second_product.reload.stock]).to eq [0, 0]
  end

end
