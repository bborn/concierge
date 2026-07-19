module Concierge
  # The read/write API over durable per-account memory. Thin on top of the Memory
  # model so retrieval stays swappable — the default is deterministic recency +
  # category matching; a pgvector/semantic drop-in can replace #recall later
  # (out of scope for v1, see design §0.5).
  class ContextStore
    def initialize(model = Concierge::Memory)
      @model = model
    end

    # Record something learned about a subject.
    def remember(subject, body:, category: nil, source: :agent, pinned: false, tier: :account)
      @model.create!(
        subject_type: subject.grain.to_s,
        subject_id:   subject.id.to_s,
        body:         body,
        category:     category,
        source:       source.to_s,
        pinned:       pinned,
        tier:         tier.to_s
      )
    end

    # Retrieve active memories for a subject, most relevant first. Deterministic:
    # filter by subject (+category, +body LIKE query when given), then order
    # pinned-then-recent.
    def recall(subject, query: nil, category: nil, limit: 20)
      rel = for_subject(subject).active
      rel = rel.by_category(category) if category
      rel = rel.where("body LIKE ?", "%#{sanitize_like(query)}%") if query.present?
      # pgvector drop-in seam: a semantic retriever would replace this ordering.
      rel.order(Arel.sql("pinned DESC, updated_at DESC")).limit(limit)
    end

    # Soft-delete: the row is retained (audit/history) but excluded from recall.
    def forget(subject, id)
      row = for_subject(subject).find_by(id: id)
      row&.update!(active: false)
      row
    end

    # The memories to inject at the top of a run's prompt: pinned + recent, with
    # human-authored rows weighted ahead of agent-authored ones. At :user grain,
    # pass the parent +account_subject+ to also fold in account-wide memory.
    def top_of_mind(subject, account_subject: nil, limit: 10)
      memories_for(subject, account_subject)
        .active
        .order(Arel.sql("CASE WHEN source = 'human' THEN 0 ELSE 1 END, pinned DESC, updated_at DESC"))
        .limit(limit)
    end

    private

    def for_subject(subject)
      @model.where(subject_type: subject.grain.to_s, subject_id: subject.id.to_s)
    end

    def memories_for(subject, account_subject)
      keys = [ [ subject.grain.to_s, subject.id.to_s ] ]
      keys << [ account_subject.grain.to_s, account_subject.id.to_s ] if account_subject
      clause = keys.map { "(subject_type = ? AND subject_id = ?)" }.join(" OR ")
      @model.where(clause, *keys.flatten)
    end

    def sanitize_like(query)
      query.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end
  end
end
