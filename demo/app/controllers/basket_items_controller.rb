# frozen_string_literal: true

# Adding to, changing, and removing from a basket. The basket is found — or
# created — through the customer's has_one inverse; adding the same product
# twice bumps the quantity instead of adding a second line.
class BasketItemsController < ApplicationController
  def create
    user = User.find(params[:basket_item][:user_id])
    product = Product.find(params[:basket_item][:product_id])
    return redirect_to(product, alert: "#{product.title} is not listed.") unless product.listed?

    basket = user.basket || user.create_basket!
    quantity = params[:basket_item][:quantity].to_i.clamp(1, 99)

    if (item = basket.items.with_related(:product, product).first)
      item.quantity += quantity
      item.save!
    else
      BasketItem.create!(basket: basket, product: product, quantity: quantity)
    end

    redirect_to user_basket_path(user), notice: "Added #{product.title} to #{helpers.display_name(user)}'s basket."
  end

  def update
    user = User.find(params[:user_id])
    item = user.basket.items.find(params[:id])
    item.quantity = params[:basket_item][:quantity].to_i.clamp(1, 99)
    item.save!
    redirect_to user_basket_path(user), notice: "Quantity updated."
  end

  def destroy
    user = User.find(params[:user_id])
    user.basket.items.find(params[:id]).destroy
    redirect_to user_basket_path(user), notice: "Removed."
  end
end
