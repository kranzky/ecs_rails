# frozen_string_literal: true

class InvoicesController < ApplicationController
  def show
    @invoice = Invoice.find(params[:id])
    @order = @invoice.order
    @items = @order.items.includes_components(Text, Counter, Money).order(created_at: :asc)
  end
end
