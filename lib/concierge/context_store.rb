module Concierge
  # The read/write API over durable per-(agent, account) memory. Thin on top of
  # the Memory model so retrieval stays swappable — the default is deterministic
  # recency + category matching; a pgvector/semantic drop-in can replace #recall
  # later (out of scope for v1, see design §0.5).
  #
  # Every method takes a Scope (an Agent × Subject pair) or a bare Subject, which
  # is coerced onto the default +:csm+ agent. The namespace policy (§10.3, settled
  # by the step-0 spike §A3) is asymmetric on purpose:
  #
  #   * WRITE -> the agent's own namespace. Sharing is an explicit opt-in
  #              (+shared: true+), because cross-function contamination is the
  #              failure mode §10.3 exists to prevent.
  #   * READ  -> #top_of_mind folds in Scope::SHARED, because a shared namespace
  #              nobody reads would be pointless. #recall does not: it is how an
  #              agent inspects what *it* knows.
  class ContextStore
    def initialize(model = Concierge::Memory)
      @model = model
    end

    # Record something learned, in this scope's own namespace (or the shared one).
    def remember(scope, body:, category: nil, source: :agent, pinned: false,
                 tier: :account, shared: false)
      scope = Scope.coerce(scope)
      @model.create!(
        **(shared ? scope.shared_key : scope.key),
        body:     body,
        category: category,
        source:   source.to_s,
        pinned:   pinned,
        tier:     tier.to_s
      )
    end

    # Retrieve active memories in this scope's own namespace, most relevant
    # first. Deterministic: filter by scope (+category, +body LIKE query when
    # given), then order pinned-then-recent.
    def recall(scope, query: nil, category: nil, limit: 20)
      rel = @model.for_scope(scope).active
      rel = rel.by_category(category) if category
      rel = rel.where("body LIKE ?", "%#{sanitize_like(query)}%") if query.present?
      # pgvector drop-in seam: a semantic retriever would replace this ordering.
      rel.order(Arel.sql("pinned DESC, updated_at DESC")).limit(limit)
    end

    # Soft-delete: the row is retained (audit/history) but excluded from recall.
    # It cannot reach across either dimension — a CSM forget never retires a
    # billing row, and never another account's.
    def forget(scope, id)
      row = @model.for_scope(scope).find_by(id: id)
      row&.update!(active: false)
      row
    end

    # The memories to inject at the top of a run's prompt: this agent's own
    # namespace plus the shared one, pinned + recent, with human-authored rows
    # weighted ahead of agent-authored ones. At :user grain, pass the parent
    # +account_scope+ to also fold in account-wide memory — the existing two-tier
    # grain composes under the agent dimension unchanged (§10.3).
    def top_of_mind(scope, account_scope: nil, limit: 10)
      memories_for(scope, account_scope)
        .active
        .order(Arel.sql("CASE WHEN source = 'human' THEN 0 ELSE 1 END, pinned DESC, updated_at DESC"))
        .limit(limit)
    end

    private

    def memories_for(scope, account_scope)
      relation = @model.for_scope_including_shared(scope)
      return relation unless account_scope

      relation.or(@model.for_scope_including_shared(account_scope))
    end

    def sanitize_like(query)
      query.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end
  end
end
