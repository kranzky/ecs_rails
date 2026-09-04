# frozen_string_literal: true

class UsersController < ApplicationController
  def index
    # includes_components(Marker) preloads every marker slot, so the badges'
    # `moderator?` / `administrator?` cost no queries on the list.
    @users = User.all.includes_components(Name, Email, Image, Marker)
  end

  def show
    @user = User.find(params[:id])
    # The inverse association (RFC-0015): user.posts is a collection.
    @posts = @user.posts
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
      bio: cap(user_params[:bio], 300).presence
    )

    if user.save
      redirect_to user, notice: "Person added."
    else
      @user = user
      render :new, status: :unprocessable_entity
    end
  end

  # The contact slots: two addresses, two phones. Each field routes to its
  # slot's component through assign_attributes on the reader; blank fields are
  # nil so an untouched slot stays virtual (no row).
  def update
    user = User.find(params[:id])
    contact = params.fetch(:contact, {})
    %w[shipping billing].each do |slot|
      attrs = contact.fetch(slot, {}).permit(*Demo::Checkout::ADDRESS_FIELDS).to_h.transform_values { |v| cap(v, 80).presence }
      user.public_send("#{slot}_address").assign_attributes(attrs)
    end
    user.mobile_phone.e164 = cap(contact[:mobile], 16).presence if contact.key?(:mobile)
    user.work_phone.e164 = cap(contact[:work], 16).presence if contact.key?(:work)

    if user.save
      redirect_to user, notice: "Contact details saved."
    else
      redirect_to user, alert: user.errors.full_messages.to_sentence
    end
  end

  private

  def user_params
    params.require(:user).permit(:first, :last, :email, :bio)
  end
end
