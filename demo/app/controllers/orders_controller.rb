# frozen_string_literal: true

class OrdersController < ApplicationController
  def index
    @user = User.find(params[:user_id])
    @orders = @user.orders.includes_components(Identifier, Money, State).order(created_at: :desc)
  end

  def show
    @order = Order.find(params[:id])
    @items = @order.items.includes_components(Text, Counter, Money).order(created_at: :asc)
    @invoice = @order.invoice
  end

  # The State component transitions itself; the order only says which
  # transitions its page offers (Order::NEXT).
  def transition
    order = Order.find(params[:id])
    order.transition!(params[:to])
    redirect_to order, notice: "Order #{order.order_number} is now #{order.status}."
  rescue ArgumentError => e
    redirect_to order, alert: e.message
  end
end
