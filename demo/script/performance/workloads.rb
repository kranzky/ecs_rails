# frozen_string_literal: true

module PerformanceComparison
  # Both representations feed the same view with the same consumed values.
  # Projection/association access is timed too, not prepared ahead of rendering.
  class Workloads
    NAMES = %w[catalogue detail preload_all preload_selected sweep checkout].freeze
    PAGE_SIZE = 24
    CARD = "4242424242424242"

    def initialize(representation)
      @ecs = representation == "ecs"
    end

    def products
      @ecs ? ::Product : Plain::Product
    end

    def catalogue_scope
      if @ecs
        products.listed.searching("common").priced_at_most(1500)
                .rated_at_least(3).in_category("books").sorted("price_asc")
      else
        products.where(status: "listed").where("document @@ plainto_tsquery('simple', ?)", "common")
                .where(amount_cents: ..1500).where("stars >= ?", 3)
                .where("tags @> ARRAY[?]::varchar[]", "books")
                .order(amount_cents: :asc, created_at: :desc, id: :asc)
      end
    end

    def catalogue
      page = catalogue_scope.page(1).per(PAGE_SIZE)
      total = page.total_count
      page = if @ecs
        page.includes_components(::Text, ::Money, ::Rating, ::Counter, ::Tags)
            .preload(seller_relationship: { target: :name_text })
      else
        page.preload(:seller)
      end
      render("catalogue", products: page.map { |product| product_values(product) }, total: total)
    end

    def detail_reviews(product)
      product.reviews.order(created_at: :desc, id: :asc).page(1).per(PAGE_SIZE)
    end

    def detail
      product = products.find(Fixtures.id("products", 2))
      reviews = detail_reviews(product)
      total = reviews.total_count
      reviews = if @ecs
        reviews.includes_components(::Text, ::Rating, ::Counter)
               .preload(author_relationship: { target: [:name, :avatar_image] })
      else
        reviews.preload(:author)
      end
      values = product_values(product).merge(body: product.body, sku: product.sku,
                                            status: @ecs ? product.listing_state.status : product.status)
      render("detail", product: values, reviews: reviews.map { |review| review_values(review) }, total: total)
    end

    def preload_all
      projection(selected: false)
    end

    def preload_selected
      projection(selected: true)
    end

    def projection(selected:)
      scope = products.order(:id).limit(PAGE_SIZE)
      scope = if @ecs
        selected ? scope.preload(:title_text, :stock_counter) : scope.includes_components(::Text, ::Counter)
      else
        selected ? scope.select(:id, :title, :stock) : scope
      end
      scope.map { |product| [product.id, product.title, product.stock] }
    end

    def sweep
      return Demo::Indexer.call(batch_size: 100) if @ecs

      # An ordinary product-specific system only visits products. Like the ECS
      # system, it performs one committed UPDATE per document, even if unchanged.
      count = 0
      Plain::Product.select(:id, *TEXT_SLOTS).find_in_batches(batch_size: 100) do |batch|
        batch.each do |product|
          text = TEXT_SLOTS.map { |slot| product.public_send(slot) }.compact.join(" ")
          Plain::Product.where(id: product.id).update_all(["document = to_tsvector('simple', ?)", text])
          count += 1
        end
      end
      count
    end

    # Setup is outside the timed checkout; pass only a freshly loaded basket
    # and revision into the operation, without cached items or product objects.
    def prepare_checkout
      customer_id = Fixtures.id("users", 0)
      if @ecs
        basket = ::Basket.for(::User.find(customer_id))
        [1, 2, 3].each { |i| basket.add_product!(products.find(Fixtures.id("products", i)), quantity: i) }
      else
        basket = Plain::Basket.find_or_create_by!(customer_id: customer_id)
        basket.with_lock do
          [1, 2, 3].each do |i|
            basket.items.create!(product_id: Fixtures.id("products", i), quantity: i)
          end
          basket.update!(revision: basket.revision + 3)
        end
      end
      @basket_id = basket.id
      @revision = basket.revision
      @basket = basket.class.find(basket.id)
    end

    def checkout(card: CARD, revision: @revision)
      service = @ecs ? Demo::Checkout : PlainCheckout
      service.call(basket: @basket, card_number: card, revision: revision,
                   shipping: ADDRESS.dup, billing: ADDRESS.dup)
    end

    def basket
      (@ecs ? ::Basket : Plain::Basket).find(@basket_id)
    end

    def product_values(product)
      { id: product.id, title: product.title, seller: product.seller.name,
        amount_cents: @ecs ? product.price_money.amount_cents : product.amount_cents,
        currency: @ecs ? product.price_money.currency : product.currency,
        stars: @ecs ? product.rating_stars : product.stars,
        tags: @ecs ? product.tags_names : product.tags,
        stock: product.stock, review_count: product.review_count }
    end

    def review_values(review)
      author = review.author
      { id: review.id, body: review.body, stars: @ecs ? review.rating_stars : review.stars,
        likes: review.likes, date: review.created_at.iso8601,
        author: @ecs ? [author.name_given, author.name_family].join(" ") : [author.given, author.family].join(" "),
        avatar: @ecs ? author.avatar_image.url : author.avatar_url }
    end

    def render(name, locals)
      ApplicationController.render(file: File.join(__dir__, "views", "#{name}.html.erb"),
                                   layout: false, locals: locals)
    end

    def plans
      connection = ActiveRecord::Base.connection
      product = products.find(Fixtures.id("products", 2))
      queries = { catalogue: catalogue_scope.limit(PAGE_SIZE).to_sql,
                  catalogue_count: catalogue_scope.except(:order).select("COUNT(*)").to_sql,
                  detail_reviews: detail_reviews(product).to_sql }
      if @ecs
        queries[:sweep_owners] = ApplicationEntity.where(id: ::Text.select(:entity_id)).order(:id).limit(100).to_sql
        ids = products.order(:id).limit(PAGE_SIZE).pluck(:id)
        queries[:title_preload] = ::Text.where(entity_id: ids, slot: "title").to_sql
        queries[:stock_preload] = ::Counter.where(entity_id: ids, slot: "stock").to_sql
      else
        queries[:sweep_products] = products.select(:id, *TEXT_SLOTS).order(:id).limit(100).to_sql
        queries[:projection] = products.select(:id, :title, :stock).order(:id).limit(PAGE_SIZE).to_sql
      end
      queries.transform_values do |sql|
        { sql: sql, explain: JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}")) }
      end
    end
  end
end
