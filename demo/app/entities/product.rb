# frozen_string_literal: true

# A listing owned by a Company. Nine catalogue components, one relationship,
# one inverse — and no migration. The price is Money under the slot `price`,
# the SKU an Identifier (unique per slot at the database), stock a Counter,
# the listing lifecycle a State, categories a Tags with an allow-list, and the
# average star rating a Rating that the reviews maintain.
class Product < ApplicationEntity
  CATEGORIES = %w[hardware books software apparel].freeze

  component Text,       prefix: :title                                  # product.title
  component Text,       prefix: :body                                   # product.body
  component Money,      prefix: :price                                  # product.price_money — amount_cents + currency
  component Identifier, prefix: :sku                                    # product.sku
  component Counter,    prefix: :stock                                  # product.stock
  component Counter,    prefix: :review_count                           # product.review_count
  component Rating                                                      # product.rating_stars — average of the reviews
  component Tags,       allow: CATEGORIES                               # product.tags_names
  component State,      prefix: :listing, states: %w[draft listed delisted]
  component SearchVector                                                # Demo::Indexer fills it from the Texts
  relates_to :seller, Company                                           # product.seller
  has_many :reviews, via: :product, dependent: :destroy                 # product.reviews

  # --- the catalogue pages: filters and sort (RFC-0018) -----------------------

  def self.listed
    with_component(State, prefix: :listing, status: "listed")
  end

  def self.searching(query)
    return all if query.blank?

    with_component(SearchVector) { matching(query) }
  end

  # "Under $50": a block on with_component, run as Money's relation.
  def self.priced_at_most(cents)
    return all if cents.nil?

    with_component(Money, prefix: :price) { where("amount_cents <= ?", cents) }
  end

  # "Four stars and up": the where-style positional form.
  def self.rated_at_least(stars)
    return all if stars.nil?

    with_component(Rating, "stars >= ?", stars)
  end

  # A category: Tags' own `tagged` scope, inside the EXISTS.
  def self.in_category(name)
    return all if name.blank?

    with_component(Tags) { tagged(name) }
  end

  SORTS = {
    "newest"     => ->(scope) { scope.order(created_at: :desc) },
    "price_asc"  => ->(scope) { scope.order_by_component(Money, :amount_cents, prefix: :price).order(created_at: :desc) },
    "price_desc" => ->(scope) { scope.order_by_component(Money, :amount_cents, :desc, prefix: :price).order(created_at: :desc) },
    "top_rated"  => ->(scope) { scope.order_by_component(Rating, :stars, :desc).order(created_at: :desc) }
  }.freeze

  def self.sorted(key)
    SORTS.fetch(key.to_s) { SORTS["newest"] }.call(all)
  end

  # --- lifecycle ---------------------------------------------------------------

  def listed?   = listing_state.in?(:listed)
  def draft?    = listing_state.status.nil? || listing_state.in?(:draft)
  def delisted? = listing_state.in?(:delisted)

  def list!   = listing_state.transition!(:listed, event: "list")
  def delist! = listing_state.transition!(:delisted, event: "delist")

  def in_stock? = stock.positive?

  # The average of the reviews' stars. There is no aggregation primitive in the
  # gem — this is plain SQL over the Rating rows of this product's reviews —
  # and the result is written back to the product's own Rating so the catalogue
  # page can filter and sort on it (RFC-0018) without touching the reviews.
  def recompute_rating!
    average = Rating.where(slot: "", entity_id: reviews.select(:id)).average(:stars)
    rating.stars = average&.round
    self.review_count = reviews.count
    save!
  end
end
