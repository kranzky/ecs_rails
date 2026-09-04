# frozen_string_literal: true

class BasketsController < ApplicationController
  def show
    @user = User.find(params[:user_id])
    @basket = @user.basket
    @items = @basket ? @basket.items.includes_components(Counter).preload(product_relationship: { target: %i[title_text price_money] }).order(created_at: :asc) : []
    @total = @basket&.total
  end
end
