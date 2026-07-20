module Concierge
  # Per-tenant + global token budgets for proactive work (design §4.3). Spend is
  # accounted per day; a run is skipped when either the account's cap or the
  # global safety rail is exhausted. Caps come from config.budget
  # ({ per_tenant:, global: }); a per-account override raises one account's cap
  # while the global rail still binds.
  class Budget
    # The ledger key every account's spend also rolls up into (the safety rail).
    GLOBAL = { subject_type: "global", subject_id: "global" }.freeze

    def initialize(ledger_model: Concierge::BudgetLedger, today: nil)
      @ledger = ledger_model
      @today  = today
    end

    # Record tokens spent on a subject's run (also counts toward the global rail).
    def spend!(subject, tokens)
      return if tokens.to_i.zero?

      [ subject.key, GLOBAL ].each { |key| bump(key, tokens) }
    end

    # Would another run for this subject exceed a cap?
    def exhausted?(subject)
      budget = Concierge.config.budget
      return false unless budget

      over?(subject.key, cap_for(subject, budget)) || over?(GLOBAL, budget[:global])
    end

    def spent_for(subject)
      spent(subject.key)
    end

    private

    def cap_for(subject, budget)
      override = Concierge.config.budget_override_for
      (override && override.call(subject)) || budget[:per_tenant]
    end

    def over?(key, cap)
      cap.present? && spent(key) >= cap
    end

    def spent(key)
      @ledger.where(**key, window_on: today).sum(:tokens_spent)
    end

    def bump(key, tokens)
      @ledger.find_or_create_by!(**key, window_on: today).increment!(:tokens_spent, tokens.to_i)
    end

    def today
      @today || Date.current
    end
  end
end
