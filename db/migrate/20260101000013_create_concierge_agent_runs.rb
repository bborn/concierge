# Per-run provenance (design §10.4). Concierge did not record *what went into a
# run's prompt*; runs were a Result object and nothing else. This is the row that
# makes "prove which policy was in force when the agent said what it said"
# answerable — the Air Canada point.
#
# One row per completed run, keyed by the (Agent × Subject) pair like every other
# per-agent table, holding:
#
#   * the memory ids injected (ContextStore#top_of_mind)
#   * the rule (id, version) pairs injected — pinned versions, so the exact text
#     is recoverable from concierge_agent_rule_revisions even after an edit
#   * the snapshot digest (per agent: two agents with different engagement
#     signals see two different pictures of one account)
#   * the ids the model *claimed* to apply, and any it cited that were not in
#     scope — a claim about a rule that was never injected is a signal worth
#     keeping rather than discarding
class CreateConciergeAgentRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_agent_runs do |t|
      t.string :agent_slug,   null: false
      t.string :subject_type, null: false
      t.string :subject_id,   null: false

      t.string :trigger, null: false          # reactive | proactive
      t.string :status,  null: false          # ok | failed
      t.string :model
      t.integer :input_tokens
      t.integer :output_tokens

      # What the prompt was assembled from.
      t.string :snapshot_digest
      t.text   :memory_ids                    # serialized JSON array
      t.text   :rules                         # serialized JSON [{id:, version:}]
      t.text   :rule_ids_applied              # serialized JSON array (cited)
      t.text   :unknown_rule_ids              # serialized JSON array (cited but not injected)

      t.string :error_class
      t.bigint :chat_id                       # the host Chat this turn landed on

      t.datetime :created_at, null: false
    end

    add_index :concierge_agent_runs,
      [ :agent_slug, :subject_type, :subject_id, :created_at ],
      name: "index_concierge_agent_runs_on_scope_and_recency"
  end
end
