# frozen_string_literal: true

module PerformanceComparison
  # ECS-38: the demo's own read paths on its own seed data, measured as whole
  # requests through the Rails stack (routing, controller, preloads, views).
  # The stress fixture in Fixtures/Workloads isolates single queries at up to
  # 5,000 products; this answers the other question, what the ordinary demo
  # pages cost, so a preload change is reported against both.
  #
  # Each page also records a SHA-256 of its HTML with the per-run noise
  # removed (UUIDs, CSRF tokens, dates and "x minutes ago"), so two runs on
  # different commits can show the same page rendered the same content. Time
  # is not frozen instead: every created_at would tie, and pages that order by
  # creation would fall back to the random UUIDs.
  module Pages
    # A fixed seed for Demo::Seed's random like counts: the HTML must not
    # differ between runs for reasons that have nothing to do with the code.
    RANDOM_SEED = 38
    UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
    TOKEN = /(name="authenticity_token" value="|name="csrf-token" content=")[^"]+/
    TIME = /(?:less than a minute|about \d+ hours?|\d+ minutes?|\d+ hours?) ago|\d{1,2} [A-Z][a-z]{2} \d{4}(?:, \d{2}:\d{2})?/

    module_function

    def seed
      Kernel.srand(RANDOM_SEED)
      Demo::Seed.call
    end

    # The paths are found from the seed rather than hard-coded: each list page,
    # plus the detail page with the most to list on it. Ties break on a name,
    # never on the random UUIDs.
    def paths
      product = Product.all.max_by { |candidate| [candidate.reviews.count, candidate.title] }
      author = User.all.max_by { |candidate| [candidate.posts.count, candidate.email_address] }
      seller = Company.all.max_by { |candidate| [candidate.products.count, candidate.name] }
      customer = User.all.max_by { |candidate| [candidate.orders.count, candidate.email_address] }
      { "catalogue" => "/products", "product" => "/products/#{product.id}",
        "user" => "/users/#{author.id}", "company" => "/companies/#{seller.id}",
        "groups" => "/groups", "geocoder" => "/geocoder", "orders" => "/users/#{customer.id}/orders",
        "posts" => "/posts", "people" => "/users" }
    end

    def run(warmups:, samples:)
      paths.map do |name, path|
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host = "localhost"
        measurements = Array.new(1 + warmups + samples) do
          measurement, status = Measurement.sample { session.get(path) }
          raise "#{path} returned #{status}" unless status == 200

          measurement
        end
        warm = measurements.drop(1 + warmups)
        html = normalise(session.response.body)
        { page: name, first_call: measurements.first, samples: warm,
          html_sha256: Digest::SHA256.hexdigest(html), html_bytes: html.bytesize,
          summary: { milliseconds: Measurement.distribution(warm.map { |row| row[:milliseconds] }),
                     allocated_objects: Measurement.distribution(warm.map { |row| row[:allocated_objects] }),
                     sql_reads: Measurement.distribution(warm.map { |row| row[:sql][:reads] }) } }
      end
    end

    def normalise(html)
      html.gsub(UUID, "<uuid>").gsub(TOKEN) { "#{Regexp.last_match(1)}<token>" }.gsub(TIME, "<time>")
    end
  end
end
