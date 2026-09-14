# frozen_string_literal: true

module PerformanceComparison
  # Executed before every measurement run (and by the CI smoke command).
  # Fail on observable differences; timings are never used as test thresholds.
  module Verify
    module_function

    def equal!(expected, actual, label)
      raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
    end

    def run(size)
      ecs = Workloads.new("ecs")
      plain = Workloads.new("plain")
      %w[catalogue detail preload_all preload_selected].each do |name|
        equal!(plain.public_send(name), ecs.public_send(name), name)
      end
      equal!(ecs.preload_all, ecs.preload_selected, "selective preload values")
      equal!([24, 3], [ecs.preload_all.size, ecs.preload_all.first.size], "projection shape")
      # Compare all matching identities as well as the bounded rendered page.
      equal!(plain.catalogue_scope.pluck(:id), ecs.catalogue_scope.pluck(:id), "filter/order identities")
      free = ::Product.find(Fixtures.id("products", 52))
      equal!(false, free.price_money.persisted?, "virtual zero price")
      equal!(true, ecs.catalogue_scope.where(id: free.id).exists?, "free product included")
      detail_product = ::Product.find(Fixtures.id("products", 2))
      equal!(30, detail_product.reviews.count, "detail review count")
      equal!(24, ecs.detail_reviews(detail_product).to_a.size, "bounded detail reviews")

      %w[ecs plain].each do |representation|
        workload = Workloads.new(representation)
        equal!(size, workload.sweep, "#{representation} indexed owners")
      end
      vectors = ::SearchVector.where(slot: "").order(:entity_id).pluck(:entity_id, :document)
      equal!(Plain::Product.order(:id).pluck(:id, :document), vectors, "complete search documents")
      equal!(size, ecs.sweep, "repeat sweep")
      equal!(vectors, ::SearchVector.where(slot: "").order(:entity_id).pluck(:entity_id, :document), "repeat documents")

      results = %w[ecs plain].map { |representation| verify_checkout(representation) }
      equal!(*results, "checkout outcomes")
      { passed: true, products: size, checks: %w[rendering filters ordering virtual_prices projections
                                                search_documents repeat_sweep committed_checkout replay
                                                decline_rollback stock snapshots addresses invoice history] }
    end

    def stock_values(workload)
      [1, 2, 3].map { |i| workload.products.find(Fixtures.id("products", i)).stock }
    end

    def row_counts
      connection = ActiveRecord::Base.connection
      connection.tables.sort.to_h do |table|
        [table, connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}")]
      end
    end

    def verify_checkout(representation)
      ecs = representation == "ecs"
      workload = Workloads.new(representation)
      workload.prepare_checkout
      before_stock = stock_values(workload)
      before_rows = row_counts
      before_revision = workload.basket.revision
      begin
        workload.checkout(card: Demo::PaymentGateway::DECLINED)
        raise "declined checkout succeeded"
      rescue Demo::Checkout::Error
        # Inspect freshly loaded state: the service's cached objects may be dirty.
        equal!(before_stock, stock_values(workload), "decline stock")
        equal!(before_rows, row_counts, "decline persisted rows")
        equal!(before_revision, workload.basket.revision, "decline revision")
        equal!(3, workload.basket.items.count, "decline basket")
      end

      order = workload.checkout
      equal!(false, ActiveRecord::Base.connection.transaction_open?, "checkout committed")
      # A second database connection must see the committed order.
      PG.connect(ENV.fetch("DATABASE_URL")) do |connection|
        table = ecs ? "entities" : "bench_orders"
        equal!("1", connection.exec_params("SELECT COUNT(*) FROM #{table} WHERE id = $1", [order.id]).getvalue(0, 0), "visible commit")
      end
      order.reload
      equal!(before_stock.zip([1, 2, 3]).map { |stock, quantity| stock - quantity }, stock_values(workload), "consumed stock")
      equal!(0, workload.basket.items.count, "cleared basket")
      equal!(before_revision + 1, workload.basket.revision, "completed revision")
      outcome = checkout_values(order, ecs)
      equal!(2000, outcome[:total], "total")
      equal!("USD", outcome[:currency], "currency")
      expected_lines = [1, 2, 3].map { |i| [Fixtures.id("products", i), "Product #{i} common", i, 100 + i * 100, "USD"] }.sort
      equal!(expected_lines, outcome[:lines], "line snapshots")
      equal!("paid", outcome[:status], "paid state")
      equal!([{"from" => "pending", "to" => "paid", "event" => "pay"}], outcome[:history], "transition")
      equal!(ADDRESS, outcome[:shipping], "shipping snapshot")
      equal!(ADDRESS, outcome[:billing], "billing snapshot")
      equal!(ADDRESS, outcome[:invoice_billing], "invoice address")
      equal!(outcome[:total], outcome[:invoice_total], "invoice total")
      equal!("ORD-000001", outcome[:number], "order numbering")
      equal!("INV-000001", outcome[:invoice_number], "invoice numbering")

      rows_after_success = row_counts
      equal!(order.id, workload.checkout.id, "replay identity")
      equal!(rows_after_success, row_counts, "replay writes no rows")
      equal!(before_stock.zip([1, 2, 3]).map { |stock, quantity| stock - quantity }, stock_values(workload), "replay stock")
      product = workload.products.find(Fixtures.id("products", 1))
      if ecs
        product.title = "Changed later"
        product.price_money.amount_cents = 9999
        product.save!
      else
        product.update!(title: "Changed later", amount_cents: 9999)
      end
      equal!(outcome, checkout_values(order.reload, ecs), "immutable snapshots")
      outcome
    end

    def address_values(record, prefix, ecs)
      if ecs
        record.public_send("#{prefix}_address").attributes.slice(*Demo::Checkout::ADDRESS_FIELDS)
      else
        Demo::Checkout::ADDRESS_FIELDS.to_h { |field| [field, record.public_send("#{prefix}_#{field}")] }
      end
    end

    def checkout_values(order, ecs)
      invoice = order.invoice
      issued_at = invoice.issued_at
      raise "missing invoice timestamp" unless issued_at.is_a?(Time)

      history = ecs ? order.fulfilment_state.transitions : order.transitions
      history.each { |entry| Time.iso8601(entry.fetch("at")) }
      { total: ecs ? order.total_money.amount_cents : order.total_cents,
        currency: ecs ? order.total_money.currency : order.currency,
        status: order.status, number: ecs ? order.order_number : order.number,
        history: history.map { |entry| entry.except("at") },
        shipping: address_values(order, "shipping", ecs), billing: address_values(order, "billing", ecs),
        lines: order.items.map { |line| [line.product_id, line.title, line.quantity,
                                       ecs ? line.unit_price_money.amount_cents : line.amount_cents,
                                       ecs ? line.unit_price_money.currency : line.currency] }.sort,
        invoice_total: ecs ? invoice.total_money.amount_cents : invoice.total_cents,
        invoice_number: ecs ? invoice.invoice_number : invoice.number,
        invoice_billing: address_values(invoice, "billing", ecs) }
    end
  end
end
