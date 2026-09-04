# frozen_string_literal: true

class UsersController < ApplicationController
  def index
    # includes_components(Marker) preloads every marker slot, so the badges'
    # `moderator?` / `administrator?` cost no queries on the list.
    @users = User.all.includes_components(Name, Email, Image, Marker)
  end

  def show
    @user = User.find(params[:id])
    @posts = Post.with_related(:author, @user)
                 .includes_components(Text, Counter, State)
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
      name_given: cap(user_params[:first], 50),
      name_family: cap(user_params[:last], 50),
      email_address: cap(user_params[:email], 100),
      bio_text_value: cap(user_params[:bio], 300).presence
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
