# frozen_string_literal: true

class ProductsController < ApplicationController
  MAX_PRICES = [10, 25, 50, 100, 250].freeze

  def index
    # Every filter is one with_component clause — a block, a where-style pair,
    # or a component's own scope (RFC-0018) — and sorting is a scalar subquery
    # in ORDER BY. All of them AND together on the same entity-scoped relation.
    @query     = params[:q].to_s.strip.first(80)
    @max_price = MAX_PRICES.include?(params[:max_price].to_i) ? params[:max_price].to_i : nil
    @min_stars = (1..5).cover?(params[:min_stars].to_i) ? params[:min_stars].to_i : nil
    @category  = Product::CATEGORIES.include?(params[:category]) ? params[:category] : nil
    @sort      = Product::SORTS.key?(params[:sort]) ? params[:sort] : "newest"

    @products = Product.listed
                       .searching(@query)
                       .priced_at_most(@max_price && @max_price * 100)
                       .rated_at_least(@min_stars)
                       .in_category(@category)
                       .sorted(@sort)
                       .includes_components(Text, Money, Rating, Counter, Tags)
                       .preload(seller_relationship: { target: :name_text })
  end

  def show
    @product = Product.find(params[:id])
    @company = @product.seller
    @reviews = @product.reviews
                       .includes_components(Text, Rating, Counter)
                       .preload(author_relationship: { target: :name })
                       .order(created_at: :desc)
    @review = Review.new
    @authors = User.all
    @staff = @company&.staff || []
  end

  def new
    @company = Company.find(params[:company_id])
    @product = Product.new
    @product.listing_state.status = "listed"
    @staff = @company.staff
  end

  def create
    @company = Company.find(params[:company_id])
    return unless authorised!(@company, :manage_products, fallback: @company)

    product = Product.new(seller: @company)
    assign(product, product_params)

    if save_product(product)
      redirect_to product, notice: product.listed? ? "Product listed." : "Draft saved."
    else
      @product = product
      @staff = @company.staff
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @product = Product.find(params[:id])
    @company = @product.seller
    @staff = @company.staff
  end

  def update
    product = Product.find(params[:id])
    @company = product.seller
    return unless authorised!(@company, :manage_products, fallback: product)

    assign(product, product_params)

    if save_product(product)
      redirect_to product, notice: "Product updated."
    else
      @product = product
      @staff = @company.staff
      render :edit, status: :unprocessable_entity
    end
  end

  def list
    product = Product.find(params[:id])
    return unless authorised!(product.seller, :manage_products, fallback: product)

    product.list!
    redirect_to product, notice: "Product listed."
  end

  def delist
    product = Product.find(params[:id])
    return unless authorised!(product.seller, :manage_products, fallback: product)

    product.delist!
    redirect_to product, notice: "Product delisted."
  end

  private

  # The demo has no sessions: management forms carry an "acting as" picker, and
  # the policy — a PORO over the Employment join entity — decides. Returns
  # false (having redirected) when the actor may not.
  def authorised!(company, action, fallback:)
    actor = User.find_by(id: params[:actor_id].presence || params.dig(:product, :actor_id))
    policy = Demo::CompanyPolicy.new(actor, company)
    return true if policy.can?(action)

    who = actor ? helpers.display_name(actor) : "Nobody"
    reason = policy.employee? ? "is #{policy.role} at #{company.name} and may not manage products" : "does not work at #{company.name}"
    redirect_to fallback, alert: "#{who} #{reason}."
    false
  end

  def assign(product, attrs)
    product.title = cap(attrs[:title], 120) if attrs.key?(:title)
    product.body = cap(attrs[:body], 5000).presence if attrs.key?(:body)
    product.sku = cap(attrs[:sku], 40).presence if attrs.key?(:sku)
    product.price_money.amount = Float(attrs[:price], exception: false)&.clamp(0, 1_000_000) || 0 if attrs.key?(:price)
    product.stock = attrs[:stock].to_i.clamp(0, 1_000_000) if attrs.key?(:stock)
    product.tags_names = Array(attrs[:categories]).select { |c| Product::CATEGORIES.include?(c) } if attrs.key?(:categories) || attrs.key?(:title)
    product.listing_state.status = attrs[:listed] == "1" ? "listed" : "draft" if attrs.key?(:listed)
  end

  # The SKU rides Identifier's unique (slot, value) index — the database, not
  # the demo, is what refuses a duplicate.
  def save_product(product)
    return false unless product.save

    product.search_vector.reindex!(product.title, product.body)
    true
  rescue ActiveRecord::RecordNotUnique
    product.errors.add(:base, "SKU #{product.sku} is already taken")
    false
  end

  def product_params
    params.require(:product).permit(:title, :body, :sku, :price, :stock, :listed, :actor_id, categories: [])
  end
end
