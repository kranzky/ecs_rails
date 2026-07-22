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

  resources :users, only: %i[index show new create] do
    # Marker components as first-class UI actions: promote/demote via add/remove.
    resource :moderator,     only: %i[create destroy], module: :users
    resource :administrator, only: %i[create destroy], module: :users
  end

  resources :groups, only: %i[index show new create] do
    resources :memberships, only: %i[create destroy], module: :groups
  end

  get "about" => "pages#about"
end
