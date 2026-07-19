module Concierge
  # Per-tenant + global token budgets for proactive work (design §4.3). Spend is
  # accounted per day; a run is skipped when either the account's cap or the
  # global safety rail is exhausted. Caps come from config.budget
  # ({ per_tenant:, global: }); a per-account override raises one account's cap
  # while the global rail still binds.
  GLOBAL_KEY = "global".freeze

  class Budget
    def initialize(ledger_model: Concierge::BudgetLedger, today: nil)
      @ledger = ledger_model
      @today  = today
    end

    # Record tokens spent on a subject's run (also counts toward the global rail).
    def spend!(subject, tokens)
      return if tokens.to_i.zero?

      bump(subject.grain.to_s, subject.id.to_s, tokens)
      bump(GLOBAL_KEY, GLOBAL_KEY, tokens)
    end

    # Would another run for this subject exceed a cap?
    def exhausted?(subject)
      budget = Concierge.config.budget
      return false unless budget

      per_tenant = cap_for(subject, budget)
      global     = budget[:global]

      (per_tenant && spent(subject.grain.to_s, subject.id.to_s) >= per_tenant) ||
        (global && spent(GLOBAL_KEY, GLOBAL_KEY) >= global)
    end

    def spent_for(subject)
      spent(subject.grain.to_s, subject.id.to_s)
    end

    private

    def cap_for(subject, budget)
      override = Concierge.config.budget_override_for
      (override && override.call(subject)) || budget[:per_tenant]
    end

    def spent(type, id)
      @ledger.where(subject_type: type, subject_id: id, window_on: today).sum(:tokens_spent)
    end

    def bump(type, id, tokens)
      row = @ledger.find_or_create_by!(subject_type: type, subject_id: id, window_on: today)
      row.increment!(:tokens_spent, tokens.to_i)
    end

    def today
      @today || Date.current
    end
  end
end
