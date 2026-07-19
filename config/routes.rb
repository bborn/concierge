Concierge::Engine.routes.draw do
  get "unsubscribe/:token", to: "unsubscribes#show", as: :unsubscribe

  resource :handoff, only: [ :create, :destroy ], path: "accounts/:subject_id/handoff" do
    post :message, on: :member
  end
end
