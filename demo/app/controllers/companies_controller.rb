# frozen_string_literal: true

class CompaniesController < ApplicationController
  def index
    @companies = paginate_list(Company.order(created_at: :asc, id: :asc)).includes_components(Text, Image, Address)
  end

  def show
    @company = Company.find(params[:id])
    @staff = paginate_list(@company.employments.order(created_at: :asc, id: :asc), param: :staff_page)
               .includes_components(Role).preload(user_relationship: { target: [:name, :avatar_image] })
    # Every product, drafts and delisted included — this is the seller's own
    # view, gated only by which actor the management forms name.
    @products = paginate_list(@company.products.order(created_at: :desc, id: :asc))
                        .includes_components(Text, Money, Counter, State, Rating)
  end
end
