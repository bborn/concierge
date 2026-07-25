Concierge::Engine.routes.draw do
  get "unsubscribe/:token", to: "unsubscribes#show", as: :unsubscribe

  post "accounts/:subject_id/chat", to: "chats#create", as: :chat

  resource :handoff, only: [ :create, :destroy ], path: "accounts/:subject_id/handoff" do
    post :message, on: :member
  end

  namespace :admin do
    resources :agents, only: [ :index ]
    resources :memories, only: [ :index, :update, :destroy ]
    resources :rules, only: [ :index, :update ]
    resources :proposals, only: [ :index, :update ]
    resources :runs, only: [ :index ]
    resources :routines, only: [ :index ]
    resources :deliveries, only: [ :index ]
  end
end
