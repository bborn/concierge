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
    def rule_ids_applied = super || []
    def unknown_rule_ids = super || []

    # The rule ids that were in the prompt, whatever the model then claimed.
    def injected_rule_ids
      rules.map { |pin| pin["id"] || pin[:id] }.compact.map(&:to_i)
    end

    # A citation for a rule that was never injected. Not an error — the model may
    # simply have hallucinated an id — but exactly the kind of thing an operator
    # should be able to see, so it is kept rather than dropped.
    def unknown_citations? = unknown_rule_ids.any?

    def total_tokens = (input_tokens || 0) + (output_tokens || 0)

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
  end
end
