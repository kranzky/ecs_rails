# frozen_string_literal: true

class CheckoutsController < ApplicationController
  def new
    @user = User.find(params[:user_id])
    @basket = @user.basket
    return redirect_to(user_basket_path(@user), alert: "The basket is empty.") if @basket.nil? || @basket.items.none?

    @total = @basket.total
  end

  def create
    @user = User.find(params[:user_id])
    basket = @user.basket
    return redirect_to(user_basket_path(@user), alert: "The basket is empty.") if basket.nil?

    order = Demo::Checkout.call(
      basket: basket,
      card_number: params[:checkout][:card_number],
      shipping: address_params(:shipping),
      billing: params[:checkout][:same_billing] == "1" ? address_params(:shipping) : address_params(:billing)
    )
    redirect_to order, notice: "Order #{order.order_number} placed and paid."
  rescue Demo::Checkout::Error => e
    redirect_to new_user_checkout_path(@user), alert: e.message
  end

  private

  def address_params(which)
    params.fetch(:checkout, {}).fetch(which, {}).permit(*Demo::Checkout::ADDRESS_FIELDS).to_h
          .transform_values { |v| cap(v, 80).presence }
  end
end
