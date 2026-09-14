# frozen_string_literal: true

module PerformanceComparison
  TEXT_SLOTS = %w[body care excerpt shipping_notes summary title].freeze
  COUNTER_SLOTS = %w[review_count return_count sale_count stock view_count wish_count].freeze
  EXTRA_TEXT_SLOTS = TEXT_SLOTS - %w[body title]
  EXTRA_COUNTER_SLOTS = COUNTER_SLOTS - %w[review_count stock]
  ADDRESS = { "line1" => "1 Main St", "line2" => "Unit 2", "locality" => "Perth",
              "region" => "WA", "postcode" => "6000", "country" => "AU" }.freeze

  # These declarations exist only in benchmark worker processes. The normal
  # demo remains unchanged; its public component/preload APIs do the work.
  EXTRA_TEXT_SLOTS.each { |slot| ::Product.component(::Text, prefix: slot.to_sym) }
  EXTRA_COUNTER_SLOTS.each { |slot| ::Product.component(::Counter, prefix: slot.to_sym) }

  module Plain
    def self.table_name_prefix = "bench_"

    class Company < ActiveRecord::Base; end
    class User < ActiveRecord::Base; end

    class Product < ActiveRecord::Base
      belongs_to :seller, class_name: "PerformanceComparison::Plain::Company"
      has_many :reviews, class_name: "PerformanceComparison::Plain::Review"
      validates :currency, format: { with: /\A[A-Z]{3}\z/ }
      validates :stars, inclusion: { in: 1..5 }, allow_nil: true
    end

    class Review < ActiveRecord::Base
      belongs_to :product
      belongs_to :author, class_name: "PerformanceComparison::Plain::User"
    end

    class Basket < ActiveRecord::Base
      belongs_to :customer, class_name: "PerformanceComparison::Plain::User"
      has_many :items, class_name: "PerformanceComparison::Plain::BasketItem", dependent: :destroy
    end

    class BasketItem < ActiveRecord::Base
      belongs_to :basket
      belongs_to :product
    end

    class Order < ActiveRecord::Base
      belongs_to :customer, class_name: "PerformanceComparison::Plain::User"
      has_many :items, class_name: "PerformanceComparison::Plain::OrderItem"
      has_one :invoice, class_name: "PerformanceComparison::Plain::Invoice"
    end

    class OrderItem < ActiveRecord::Base
      belongs_to :order
      belongs_to :product
    end

    class Invoice < ActiveRecord::Base
      belongs_to :order
    end
  end
end
