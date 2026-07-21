# frozen_string_literal: true

class GroupsController < ApplicationController
  def index
    @groups = Group.all.includes_components(Name, Description)
  end

  def show
    @group = Group.find(params[:id])
    # Members: Membership join entities whose :group relationship points here,
    # each resolved to its user + role.
    @memberships = Membership
                   .with_component(Membership::GroupRelationship, group_id: @group.id)
                   .includes_components(Role)
                   .preload(user_relationship: { user: :name })
    @candidates = User.all.includes_components(Name)
  end

  def new
    @group = Group.new
  end

  def create
    group = Group.new
    group.name.first = group_params[:name]
    group.description.text = group_params[:description] if group_params[:description].present?

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
