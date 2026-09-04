# frozen_string_literal: true

class GroupsController < ApplicationController
  def index
    # includes_components(Description) preloads BOTH slots (the plain
    # description and the :rules one), one query each.
    @groups = Group.all.includes_components(Name, Description)
  end

  def show
    @group = Group.find(params[:id])
    # Members: Membership join entities whose :group relationship points here,
    # by relationship name (RFC-0013). The member name is a two-hop preload.
    @memberships = Membership
                   .with_related(:group, @group)
                   .includes_components(Role)
                   .preload(user_relationship: { target: :name })
    @candidates = User.all.includes_components(Name)
  end

  def new
    @group = Group.new
  end

  def create
    # Flat mass assignment: prefixed delegated writers mean assign_attributes
    # routes each key to its component (ADR-0016). `.presence` keeps a blank
    # description at its nil default, so no Description row is written for it.
    group = Group.new(
      name_first: cap(group_params[:name], 80),
      description_text: cap(group_params[:description], 300).presence,
      rules_description_text: cap(group_params[:rules], 500).presence
    )

    if group.save
      redirect_to group, notice: "Group created."
    else
      @group = group
      render :new, status: :unprocessable_entity
    end
  end

  private

  def group_params
    params.require(:group).permit(:name, :description, :rules)
  end
end
