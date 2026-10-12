# frozen_string_literal: true

class GroupsController < ApplicationController
  def index
    # The list shows each group's name and description. includes_components(Text)
    # would preload all three Text slots, rules included, one query each; naming
    # the two it shows skips the third (ECS-38).
    @groups = paginate_list(Group.order(created_at: :asc, id: :asc)).preload(:name_text, :description_text)
  end

  def show
    @group = Group.find(params[:id])
    # Members: the inverse of Membership's :group relationship (RFC-0015), a
    # real collection. The member name is a two-hop preload.
    @memberships = paginate_list(@group.memberships.order(created_at: :asc, id: :asc))
                         .includes_components(Role)
                         .preload(user_relationship: { target: [:name, :avatar_image] })
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
      name: cap(group_params[:name], 80),
      description: cap(group_params[:description], 300).presence,
      rules: cap(group_params[:rules], 500).presence
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
