Concierge::Engine.routes.draw do
  get "unsubscribe/:token", to: "unsubscribes#show", as: :unsubscribe

  post "accounts/:subject_id/chat", to: "chats#create", as: :chat

  resource :handoff, only: [ :create, :destroy ], path: "accounts/:subject_id/handoff" do
    post :message, on: :member
  end

  namespace :admin do
    resources :memories, only: [ :index, :update, :destroy ]
    resources :routines, only: [ :index ]
    resources :deliveries, only: [ :index ]

    # Throwaway (Agent × Subject) spike screen — 404s unless the flag is on.
    get  "spike",      to: "spike#index", as: :spike
    post "spike/runs", to: "spike#run",   as: :spike_runs
  end
end
