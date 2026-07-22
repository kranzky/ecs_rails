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
    user.name.first = cap(user_params[:first], 50)
    user.name.last = cap(user_params[:last], 50)
    user.email.address = cap(user_params[:email], 100)
    user.bio.text = cap(user_params[:bio], 300) if user_params[:bio].present?

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
