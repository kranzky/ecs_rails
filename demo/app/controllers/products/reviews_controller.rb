# frozen_string_literal: true

class Products::ReviewsController < ApplicationController
  def create
    product = Product.find(params[:product_id])
    return redirect_to(product, alert: "Only listed products can be reviewed.") unless product.listed?

    review = Review.new(body: cap(params.dig(:review, :body), 2000).presence, product: product)
    review.rating_stars = params.dig(:review, :stars).to_i.clamp(1, 5)
    review.author = User.find(params[:review][:author_id]) if params.dig(:review, :author_id).present?

    if review.save
      product.recompute_rating!
      redirect_to product, notice: "Review added."
    else
      redirect_to product, alert: review.errors.full_messages.to_sentence.presence || "Review could not be saved."
    end
  end
end
