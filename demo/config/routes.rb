# frozen_string_literal: true

Rails.application.routes.draw do
  # Health check for uptime monitors / Fly (config.silence_healthcheck_path).
  get "up" => "rails/health#show", as: :rails_health_check

  root "posts#index"

  resources :posts, only: %i[index show new create edit update] do
    member { patch :publish }
    resource  :like,     only: :create, module: :posts
    resources :comments, only: :create, module: :posts
  end

  resources :comments, only: [] do
    resource :like, only: :create, module: :comments
  end

  resources :users, only: %i[index show new create update] do
    # Marker components as first-class UI actions: promote/demote via add/remove.
    resource :moderator,     only: %i[create destroy], module: :users
    resource :administrator, only: %i[create destroy], module: :users
    # The marketplace (ECS-23): a user's basket, checkout and orders. No
    # sessions — the user in the path is the customer.
    resource  :basket,       only: :show
    resources :basket_items, only: %i[update destroy]
    resource  :checkout,     only: %i[new create]
    resources :orders,       only: :index
  end
  resources :basket_items, only: :create
  resources :orders, only: :show do
    member { patch :transition }
  end
  resources :invoices, only: :show

  resources :groups, only: %i[index show new create] do
    resources :memberships, only: %i[create destroy], module: :groups
  end

  # The marketplace (ECS-22): products with filters and sort, reviews, sellers.
  resources :products, only: %i[index show new create edit update] do
    member do
      patch :list
      patch :delist
    end
    resources :reviews, only: :create, module: :products
  end
  resources :companies, only: %i[index show]

  get "about" => "pages#about"
end
