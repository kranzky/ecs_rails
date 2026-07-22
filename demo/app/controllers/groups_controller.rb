# frozen_string_literal: true

class GroupsController < ApplicationController
  def index
    @groups = Group.all.includes_components(Name, Description)
  end

  def show
    @group = Group.find(params[:id])
    # Members: Membership join entities whose :group relationship points here,
    # by relationship name (RFC-0013). The member name is a two-hop preload.
    @memberships = Membership
                   .with_related(:group, @group)
                   .includes_components(Role)
                   .preload(user_relationship: { user: :name })
    @candidates = User.all.includes_components(Name)
  end

  def new
    @group = Group.new
  end

  def create
    group = Group.new
    group.name.first = cap(group_params[:name], 80)
    group.description.text = cap(group_params[:description], 300) if group_params[:description].present?

    if group.save
      redirect_to group, notice: "Group created."
    else
      @group = group
      render :new, status: :unprocessable_entity
    end
  end

  private

  def group_params
    params.require(:group).permit(:name, :description)
  end
end
