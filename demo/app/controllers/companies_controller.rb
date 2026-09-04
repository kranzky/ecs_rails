# frozen_string_literal: true

class CompaniesController < ApplicationController
  def index
    @companies = Company.all.includes_components(Text, Image, Address).order(created_at: :asc)
  end

  def show
    @company = Company.find(params[:id])
    @staff = @company.staff
    # Every product, drafts and delisted included — this is the seller's own
    # view, gated only by which actor the management forms name.
    @products = @company.products
                        .includes_components(Text, Money, Counter, State, Rating)
                        .order(created_at: :desc)
  end
end
