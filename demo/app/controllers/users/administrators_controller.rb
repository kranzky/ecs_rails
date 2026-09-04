# frozen_string_literal: true

class Users::AdministratorsController < ApplicationController
  def create
    user = User.find(params[:user_id])
    user.add(:administrator)
    redirect_to user, notice: "#{helpers.display_name(user)} is now an administrator."
  end

  def destroy
    user = User.find(params[:user_id])
    user.remove(:administrator)
    redirect_to user, notice: "#{helpers.display_name(user)} is no longer an administrator."
  end
end
