module Concierge
  module Spike
    # SPIKE (phase-10 step 0, §10.3). Throwaway — see lib/concierge/spike.rb.
    #
    # ContextStore, keyed by (Agent × Subject) instead of Subject alone. Same
    # rows, same table, same deterministic ordering — the only change is that the
    # key gained a dimension, which is the whole point of the spike.
    #
    # Namespace policy (the thing this spike is here to judge):
    #   * WRITE  -> the agent's own namespace. Sharing is an explicit opt-in
    #               (+shared: true+), because cross-function contamination is the
    #               failure mode §10.3 exists to prevent.
    #   * READ   -> the agent's own namespace + Scope::SHARED. A shared namespace
    #               nobody reads would be pointless; the isolation that matters is
    #               that agent A never reads agent B's *private* notes.
    class MemoryStore
      def initialize(model = Concierge::Memory)
        @model = model
      end

      # Record something learned, in this scope's namespace.
      def remember(scope, body:, category: nil, source: :agent, pinned: false,
                   tier: :account, shared: false)
        @model.create!(
          **(shared ? scope.shared_key : scope.key),
          body:     body,
          category: category,
          source:   source.to_s,
          pinned:   pinned,
          tier:     tier.to_s
        )
      end

      # Active memories in this scope's own namespace only — a deliberate
      # narrowing: recall is how an agent inspects what *it* knows.
      def recall(scope, query: nil, category: nil, limit: 20)
        rel = @model.for_scope(scope).active
        rel = rel.by_category(category) if category
        rel = rel.where("body LIKE ?", "%#{sanitize_like(query)}%") if query.present?
        rel.order(Arel.sql("pinned DESC, updated_at DESC")).limit(limit)
      end

      def forget(scope, id)
        row = @model.for_scope(scope).find_by(id: id)
        row&.update!(active: false)
        row
      end

      # What goes at the top of a run's prompt: this agent's own memory plus the
      # shared namespace, human-authored rows weighted ahead of agent-authored.
      def top_of_mind(scope, limit: 10)
        namespaced(scope)
          .active
          .order(Arel.sql("CASE WHEN source = 'human' THEN 0 ELSE 1 END, pinned DESC, updated_at DESC"))
          .limit(limit)
      end

      private

      def namespaced(scope)
        keys   = [ scope.key, scope.shared_key ]
        clause = keys.map { "(subject_type = ? AND subject_id = ?)" }.join(" OR ")
        @model.where(clause, *keys.flat_map(&:values))
      end

      def sanitize_like(query)
        query.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }
      end
    end
  end
end
