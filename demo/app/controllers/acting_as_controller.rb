# frozen_string_literal: true

# Switches who the visitor acts as (see ApplicationController#acting_user),
# then returns them to the page they were on.
class ActingAsController < ApplicationController
  def update
    user = User.find(params[:user_id])
    session[:acting_as_id] = user.id
    redirect_back fallback_location: root_path, notice: "You are now acting as #{helpers.display_name(user)}."
  end
end
