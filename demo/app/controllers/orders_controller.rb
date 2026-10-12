# frozen_string_literal: true

class OrdersController < ApplicationController
  def index
    @user = User.find(params[:user_id])
    # The list shows the order number, total and status. Identifier is also
    # the checkout's idempotency key, which the list never shows (ECS-38).
    @orders = paginate_list(@user.orders.order(created_at: :desc, id: :asc))
                .preload(:order_number_identifier, :total_money, :fulfilment_state)
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
