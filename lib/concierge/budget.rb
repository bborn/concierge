module Concierge
  # Per-tenant + global token budgets for proactive work (design §4.3). Spend is
  # accounted per day; a run is skipped when either the account's cap or the
  # global safety rail is exhausted. Caps come from config.budget
  # ({ per_tenant:, global: }); a per-account override raises one account's cap
  # while the global rail still binds.
  # Spend is *attributed* per (agent, subject) so an operator can see which
  # business function burned the tokens, but the per-tenant **cap** is still read
  # across every agent: a tenant's daily cap is the tenant's, and per-agent caps
  # would let N agents each spend it. Same rule as the governance rails — the
  # customer-facing limits are per-customer, the namespaces are per-agent.
  class Budget
    # The ledger key every account's spend also rolls up into (the safety rail).
    # It belongs to no agent, so it carries its own reserved namespace.
    GLOBAL_AGENT_SLUG = "_global".freeze
    GLOBAL = { agent_slug: GLOBAL_AGENT_SLUG, subject_type: "global", subject_id: "global" }.freeze

    def initialize(ledger_model: Concierge::BudgetLedger, today: nil)
      @ledger = ledger_model
      @today  = today
    end

    # Record tokens spent on one agent's run for a subject (also counts toward
    # the global rail).
    def spend!(scope, tokens)
      return if tokens.to_i.zero?

      [ Scope.coerce(scope).key, GLOBAL ].each { |key| bump(key, tokens) }
    end

    # Would another run for this subject exceed a cap?
    def exhausted?(scope)
      budget = Concierge.config.budget
      return false unless budget

      subject = Scope.coerce(scope).subject
      over?(Scope.subject_key(scope), cap_for(subject, budget)) || over?(GLOBAL, budget[:global])
    end

    # This subject's spend today, across every agent.
    def spent_for(subject)
      spent(Scope.subject_key(subject))
    end

    # One agent's share of it.
    def spent_for_scope(scope)
      spent(Scope.coerce(scope).key)
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
