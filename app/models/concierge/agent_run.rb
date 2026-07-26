module Concierge
  # What went into one run's prompt (design §10.4). Runs used to leave no trace
  # but a Result object and whatever the model said; this row is the difference
  # between "the agent probably followed policy" and "here is the exact policy
  # text, versioned, that was in the prompt for this decision."
  #
  # Keyed by the (Agent × Subject) pair like every other per-agent table, so an
  # audit of one business function's decisions cannot pull in another's.
  class AgentRun < ApplicationRecord
    include AgentScoped

    TRIGGERS = %w[reactive proactive].freeze
    STATUSES = %w[ok failed].freeze

    serialize :memory_ids,       coder: JSON, type: Array
    serialize :rules,            coder: JSON, type: Array
    serialize :rule_ids_applied, coder: JSON, type: Array
    serialize :unknown_rule_ids, coder: JSON, type: Array

    validates :trigger, inclusion: { in: TRIGGERS }
    validates :status,  inclusion: { in: STATUSES }

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :ok,     -> { where(status: "ok") }

    def memory_ids      = super || []
    def rules           = super || []
    def unknown_rule_ids = super || []

    # The model's own claim about which rules it applied, parsed off the citation
    # line in its reply — **not** evidence that any of them were followed.
    #
    # `rules` above is engine-written and proves what the agent was told.
    # This is model-written and proves only what the model said about itself. A
    # live model has been observed contradicting an advisory rule while sincerely
    # citing it (design §10.4), and that run records identically to a compliant
    # one: same pins, a citation, no unknown ids. The engine cannot tell them
    # apart, because it never sees the rule's meaning — only its id coming back.
    #
    # Kept because it answers "did the rule reach the model's attention at all?"
    # (what RuleDreamingJob's "never cited" evidence rests on) and because the
    # cross-check below catches invented ids. Never surface it as compliance.
    def rule_ids_applied = super || []

    # The rule ids that were in the prompt, whatever the model then claimed.
    def injected_rule_ids
      rules.map { |pin| pin["id"] || pin[:id] }.compact.map(&:to_i)
    end

    # A citation for a rule that was never injected. Not an error — the model may
    # simply have hallucinated an id — but exactly the kind of thing an operator
    # should be able to see, so it is kept rather than dropped.
    def unknown_citations? = unknown_rule_ids.any?

    def total_tokens = (input_tokens || 0) + (output_tokens || 0)

    # --- what the agent actually said ----------------------------------------
    #
    # The pins prove what the agent was told; the citation is only what it says
    # it did. Neither can distinguish a turn that followed an advisory rule from
    # one that contradicted it and cited it anyway — those two runs record
    # identically (design §10.4). Reading the reply is the check the engine
    # cannot perform, so an operator has to be able to reach it.
    #
    # It is reached, never stored. The reply is customer-facing text living in
    # the host's own chat tables under the host's own retention policy; copying
    # it onto a provenance row that Concierge prunes on a different cadence would
    # be the engine deciding a privacy question that belongs to the host (§10.12).
    # So this resolves live, and answers honestly when the host has pruned.

    # The host Chat this turn landed on, or nil once the host has dropped it.
    def chat_record
      return unless chat_id

      Concierge.chat_model.find_by(id: chat_id)
    rescue StandardError
      # The host is free to remove the model or the table entirely. A missing
      # conversation is an answer, not an error.
      nil
    end

    # The assistant message this run produced.
    #
    # Looked up *through this run's own chat*, never by id against the host's
    # whole message table. That is the isolation property: even a wrong or stale
    # +message_id+ can only ever fail to resolve — it can never surface another
    # agent's or another account's conversation.
    def reply_message
      return unless message_id

      messages_of(chat_record)&.find_by(id: message_id)
    end

    # The raw assistant message as the host persisted it. Raw is the point: this
    # is what the model emitted, citation line and all, before Concierge stripped
    # that line out of the customer-facing +Result#reply_text+.
    def reply_text
      reply_message&.content.presence
    end

    # Why the reply cannot be read, when it cannot. nil means it can.
    def reply_unavailable_reason
      return if reply_text
      return :no_host_chat if chat_id.nil?
      return :not_persisted if message_id.nil?

      :pruned
    end

    # The exact instruction text this run was given, resolved through the pinned
    # versions. Falls back to the rule's current body only when the trail has no
    # revision at that version (a rule created before the trail existed).
    def injected_rule_texts
      rules.filter_map do |pin|
        rule = AgentRule.find_by(id: pin["id"] || pin[:id])
        next unless rule

        version  = pin["version"] || pin[:version]
        revision = rule.revision_at(version)
        "[rule #{rule.id} v#{version}] #{(revision&.body || rule.body).to_s.strip}"
      end
    end

    # Retention (§10.12): a row per run is real write volume. Hosts prune on their
    # own cadence — the engine ships the door, not a policy, because how long
    # "prove what the agent was told" has to stay answerable is a compliance
    # question, not a library one.
    def self.prune!(older_than:)
      where(created_at: ...older_than.ago).delete_all
    end

    private

    # Whatever the host named its messages association.
    def messages_of(chat)
      return unless chat
      return chat.messages_association if chat.respond_to?(:messages_association)

      chat.messages if chat.respond_to?(:messages)
    end
  end
end
