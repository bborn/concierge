module Concierge
  # Daily token-spend accounting per (agent, subject), plus a global row. See
  # Concierge::Budget for why the *cap* is still read across agents even though
  # spend is now attributed to one.
  class BudgetLedger < ApplicationRecord
    include AgentScoped
  end
end
