# frozen_string_literal: true

# Membership is a join ENTITY (ADR-0005): many-to-many modelled as its own
# entity carrying two relationships plus a Role. Adding a member creates one.
class Groups::MembershipsController < ApplicationController
  def create
    group = Group.find(params[:group_id])
    user = User.find(params[:membership][:user_id])

    membership = Membership.create!(
      user: user,
      group: group,
      role_name: cap(params[:membership][:role], 30).presence || "member"
    )

    redirect_to group, notice: "#{helpers.display_name(user)} joined #{group.name_first}."
  end

  def destroy
    membership = Membership.find(params[:id])
    group = membership.group
    membership.destroy
    redirect_to group, notice: "Member removed."
  end
end
