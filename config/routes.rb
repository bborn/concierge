Concierge::Engine.routes.draw do
  get "unsubscribe/:token", to: "unsubscribes#show", as: :unsubscribe

  post "accounts/:subject_id/chat", to: "chats#create", as: :chat

  resource :handoff, only: [ :create, :destroy ], path: "accounts/:subject_id/handoff" do
    post :message, on: :member
  end

  # The inbound approval-intake seam (design §10.7). Two endpoints, because a real
  # Slack app needs both: events for the URL handshake and case-thread replies,
  # interactivity for the button that says who clicked it.
  post "slack/events",       to: "slack#events",       as: :slack_events
  post "slack/interactions", to: "slack#interactions",  as: :slack_interactions

  namespace :admin do
    resources :agents, only: [ :index ]
    # "slack" is uncountable, so a resources declaration would name this
    # admin_slack_index_path. It is one screen; give it the obvious helper.
    get "slack", to: "slack#index", as: :slack
    resources :memories, only: [ :index, :update, :destroy ]
    resources :rules, only: [ :index, :update ]
    resources :proposals, only: [ :index, :update ]
    resources :runs, only: [ :index, :show ]
    resources :routines, only: [ :index ]
    resources :deliveries, only: [ :index ]
  end
end
