# frozen_string_literal: true

Rails.application.routes.draw do
  root "posts#index"
  resources :posts, only: %i[index show new create] do
    resource :like, only: :create, module: :posts
  end
end
