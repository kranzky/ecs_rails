# frozen_string_literal: true

class UsersController < ApplicationController
  def index
    @users = User.all.includes_components(Name, Email, Avatar, Moderator, Administrator)
  end

  def show
    @user = User.find(params[:id])
    @posts = Post.with_related(:author, @user)
                 .includes_components(Title, Likes, PublishState)
                 .order(created_at: :desc)
  end

  def new
    @user = User.new
  end

  def create
    user = User.new
    user.name.first = user_params[:first]
    user.name.last = user_params[:last]
    user.email.address = user_params[:email]
    user.bio.text = user_params[:bio] if user_params[:bio].present?

    if user.save
      redirect_to user, notice: "Person added."
    else
      @user = user
      render :new, status: :unprocessable_entity
    end
  end

  private

  def user_params
    params.require(:user).permit(:first, :last, :email, :bio)
  end
end
