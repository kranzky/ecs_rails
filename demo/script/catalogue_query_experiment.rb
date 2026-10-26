# frozen_string_literal: true

# ECS-42 experiment: can ordinary Rails relation changes make the catalogue's
# filtered, sorted page cheaper? The decision and the numbers are in
# docs/design/catalogue-queries.md; nothing here changes the demo.
#
#   bundle exec ruby script/catalogue_query_experiment.rb [--sizes 100,5000] [--output PATH]
#
# Like compare_performance.rb it creates an owned database per size, loads the
# ECS-33 fixture with the harness's own worker (ANALYZE included), measures in a
# fresh Rails process, and drops the database. DATABASE_URL names the server.
require "json"
require "open3"
require "optparse"
require "securerandom"
require "uri"

if ENV["ECS_CATALOGUE_EXPERIMENT"]
  abort "Use the experiment orchestrator" unless ENV["RAILS_ENV"] == "test" &&
    ENV.fetch("ECS_PERFORMANCE_DATABASE", "").match?(/\Aecs_performance_[0-9a-f]+\z/)
  require_relative "../config/environment"
  abort "Database does not belong to this run" unless
    ActiveRecord::Base.connection_db_config.database == ENV.fetch("ECS_PERFORMANCE_DATABASE")
  ActiveRecord::Base.logger = nil
  Rails.application.eager_load!

  # The same filters three ways. V0 is the demo's own scopes; V1 and V2 are
  # candidate rewrites in plain Rails, kept only in this script.
  VARIANTS = {
    # with_component: one correlated EXISTS per filter (RFC-0010/0018).
    "v0_exists" => lambda do |q:, max: nil, stars: nil, category: nil, sort:|
      Product.listed.searching(q).priced_at_most(max).rated_at_least(stars).in_category(category).sorted(sort)
    end,
    # The same predicates as IN subqueries on each component table.
    "v1_in" => lambda do |q:, max: nil, stars: nil, category: nil, sort:|
      scope = Product.where(id: State.where(slot: "listing", status: "listed").select(:entity_id))
      scope = scope.where(id: SearchVector.matching(q).select(:entity_id)) if q.present?
      scope = scope.priced_at_most(max)
      scope = scope.where(id: Rating.where("stars >= ?", stars).select(:entity_id)) if stars
      scope = scope.where(id: Tags.tagged(category).select(:entity_id)) if category
      scope.sorted(sort)
    end,
    # Inner joins on the slot-scoped has_ones: unique per (entity_id, slot), so
    # still one row per product, and the planner may hash-join them.
    "v2_joins" => lambda do |q:, max: nil, stars: nil, category: nil, sort:|
      scope = Product.joins(:listing_state).where(states: { status: "listed" })
      scope = scope.joins(:search_vector).merge(SearchVector.matching(q)) if q.present?
      scope = scope.priced_at_most(max)
      scope = scope.joins(:rating).where("ratings.stars >= ?", stars) if stars
      scope = scope.joins(:tags).merge(Tags.tagged(category)) if category
      scope.sorted(sort)
    end
  }.freeze

  SCENARIOS = {
    "broad" => { q: "common", max: 1500, stars: 3, category: "books", sort: "price_asc" },
    "selective_search" => { q: "42", sort: "newest" },
    "unfiltered" => { q: nil, sort: "newest" },
    "price_ties" => { q: nil, max: 1500, sort: "price_asc" },
    "top_rated" => { q: nil, stars: 4, sort: "top_rated" }
  }.freeze

  # The demo controller's preload policy since ECS-38, the same for every variant.
  def preload_page(page)
    page.preload(:title_text, :price_money, :rating, :stock_counter, :review_count_counter, :tags,
                 seller_relationship: { target: :name_text })
  end

  # Median of five EXPLAIN ANALYZE runs: one run is too noisy to compare.
  def explain(relation)
    plans = Array.new(5) do
      JSON.parse(ActiveRecord::Base.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{relation.to_sql}")).first
    end
    median = ->(key) { plans.map { |plan| plan[key] }.sort[2] }
    { execution_ms: median.call("Execution Time"), planning_ms: median.call("Planning Time"),
      shared_hits: plans.first.dig("Plan", "Shared Hit Blocks"), top_node: plans.first.dig("Plan", "Node Type") }
  end

  def warm(samples)
    times = []
    allocations = []
    ActiveRecord::Base.uncached do
      3.times { yield }
      samples.times do
        GC.start
        allocated = GC.stat(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        allocations << GC.stat(:total_allocated_objects) - allocated
      end
    end
    times.sort!
    allocations.sort!
    { p50_ms: times[samples / 2], p95_ms: times[(samples * 0.95).ceil - 1], allocations_p50: allocations[samples / 2] }
  end

  samples = Integer(ENV.fetch("ECS_SAMPLES", "30"))
  measure = lambda do |scenario, filters, name, build, reference|
    relation = build.call(**filters)
    page = relation.page(1).per(24)
    found = [page.pluck(:id), page.total_count]
    raise "#{scenario}/#{name} differs from v0" unless reference.nil? || found == reference

    [found, { page_query: explain(page), count_query: explain(relation.unscope(:order).select(Arel.sql("COUNT(*)"))),
              request: warm(samples) { preload_page(build.call(**filters).page(1).per(24)).tap { |p| p.to_a; p.total_count } } }]
  end
  results = SCENARIOS.to_h do |scenario, filters|
    reference = nil
    variants = VARIANTS.to_h do |name, build|
      found, measured = measure.call(scenario, filters, name, build, reference)
      reference ||= found
      [name, measured]
    end
    [scenario, { matches: reference.last, variants: variants, reference: reference }]
  end

  # Not a relation change: what one shared index on entities would do for the
  # orders that start from an entity's creation time. Measured last, because
  # it changes every later plan in this database.
  connection = ActiveRecord::Base.connection
  connection.execute("CREATE INDEX ecs42_entities_model_created ON entities (model, created_at DESC, id)")
  connection.execute("ANALYZE entities")
  SCENARIOS.each do |scenario, filters|
    _, measured = measure.call(scenario, filters, "v0_with_index", VARIANTS.fetch("v0_exists"), results[scenario].delete(:reference))
    results[scenario][:variants]["v0_with_entities_index"] = measured
  end
  File.write(ENV.fetch("ECS_OUTPUT"), JSON.pretty_generate(results) + "\n")
  exit
end

options = { sizes: [100, 5000], output: File.expand_path("../../tmp/ecs42-catalogue.json", __dir__) }
OptionParser.new do |parser|
  parser.on("--sizes N,N", Array) { |values| options[:sizes] = values.map { |value| Integer(value) } }
  parser.on("--output PATH") { |value| options[:output] = File.expand_path(value) }
end.parse!

root = File.expand_path("..", __dir__)
admin = URI(ENV.fetch("DATABASE_URL", "postgresql:///postgres"))
results = { measured_at: Time.now.utc.to_s,
            commit: Open3.capture2("git", "rev-parse", "HEAD", chdir: root).first.strip, sizes: {} }
options[:sizes].each do |size|
  database = "ecs_performance_#{SecureRandom.hex(8)}"
  url = admin.dup
  url.path = "/#{database}"
  environment = { "DATABASE_URL" => url.to_s, "RAILS_ENV" => "test", "DEMO_RESET_ENABLED" => "false",
                  "ECS_PERFORMANCE_DATABASE" => database, "CI" => nil }
  system("createdb", database, exception: true)
  begin
    puts "Preparing #{size} products in #{database}"
    prepared = File.join(root, "tmp", "#{database}-prepare.json")
    _, status = Open3.capture2e(environment, RbConfig.ruby, "script/performance/worker.rb", "prepare", prepared, size.to_s, chdir: root)
    abort "prepare failed" unless status.success?
    File.delete(prepared)

    output = File.join(root, "tmp", "#{database}-catalogue.json")
    log, status = Open3.capture2e(environment.merge("ECS_CATALOGUE_EXPERIMENT" => "1", "ECS_OUTPUT" => output),
                                  RbConfig.ruby, __FILE__, chdir: root)
    abort "experiment failed:\n#{log}" unless status.success?
    results[:sizes][size] = JSON.parse(File.read(output))
    File.delete(output)
  ensure
    system("dropdb", database)
  end
end
File.write(options[:output], JSON.pretty_generate(results) + "\n")
puts "Results: #{options[:output]}"
