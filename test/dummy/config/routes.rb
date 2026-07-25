Rails.application.routes.draw do
  mount Concierge::Engine => "/concierge"

  # --- Acme: the host product a person actually uses ------------------------
  root "changelog_entries#index"

  get    "signin",  to: "sessions#new",     as: :signin
  post   "signin",  to: "sessions#create"
  delete "signout", to: "sessions#destroy", as: :signout

  resources :changelog_entries, path: "changelog", except: [ :show ] do
    member do
      post :publish
      post :unpublish
    end
  end

  get  "inbox",           to: "inbox#index",    as: :inbox
  post "inbox/read_all",  to: "inbox#read_all", as: :read_all_inbox
  post "inbox/:id/read",  to: "inbox#read",     as: :read_inbox_message

  get "account", to: "account#show", as: :account

  # The gated path, from the customer's side: this stages an AgentProposal under
  # the :billing agent's authority envelope. Approving it in the engine admin is
  # what actually changes the plan.
  post "account/plan_change", to: "plan_changes#create", as: :plan_change

  # "Talk to a human" — opens/closes a Concierge::Handoff on the CSM thread.
  post   "account/handoff", to: "handoffs#create",  as: :handoff
  delete "account/handoff", to: "handoffs#destroy"

  # "Kit, take a look": run the proactive path on demand rather than waiting a
  # week for the sweep. Local environments only.
  post "agent/review",   to: "agent#review",   as: :agent_review
  get  "agent/activity", to: "agent#activity", as: :agent_activity
end
