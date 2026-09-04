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
    # Flat mass assignment (ADR-0016): each prefixed key is a delegated writer,
    # so ActiveRecord routes it to the right component and the save cascade
    # persists only the components that ended up dirty. `.presence` matters: a
    # blank bio must stay nil (the column default) or the Bio component is
    # dirtied by "" and gets a row for nothing.
    user = User.new(
      name_first: cap(user_params[:first], 50),
      name_last: cap(user_params[:last], 50),
      email_address: cap(user_params[:email], 100),
      bio_text: cap(user_params[:bio], 300).presence
    )

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
