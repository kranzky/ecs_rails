# frozen_string_literal: true

# The marker component (RFC-0009) as a UI action: a user IS a moderator exactly
# when the Moderator row exists. Promote = add, demote = remove.
class Users::ModeratorsController < ApplicationController
  def create
    user = User.find(params[:user_id])
    user.add(Moderator)
    redirect_to user, notice: "#{name_of(user)} is now a moderator."
  end

  def destroy
    user = User.find(params[:user_id])
    user.remove(Moderator)
    redirect_to user, notice: "#{name_of(user)} is no longer a moderator."
  end

  private

  def name_of(user)
    helpers.display_name(user)
  end
end
