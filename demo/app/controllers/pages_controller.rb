# frozen_string_literal: true

class PagesController < ApplicationController
  # The tour at the root (ECS-35): compose, use, inspect, extend. Each step
  # links to a live page, for the acting user where there is one.
  def start
    latest_order = acting_user&.orders&.order(created_at: :desc, id: :asc)&.first
    @invoice = latest_order&.invoice || Invoice.order(created_at: :desc, id: :asc).first
  end

  def about; end
end
