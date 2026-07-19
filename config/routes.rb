Concierge::Engine.routes.draw do
  get "unsubscribe/:token", to: "unsubscribes#show", as: :unsubscribe
end
