# This migration comes from concierge (originally 20260101000012)
# The Memory / Rules split (design §10.2). Memory keeps doing what it does —
# episodic, recency-ranked facts about one relationship. Rules are the other
# thing Memory was quietly doing: *generalized, versioned, human-gated
# behavioral instructions with a lifecycle.*
#
# Two tables, because "which text was in force at 14:02" is only answerable if
# every edit leaves a trail:
#
#   concierge_agent_rules           the rule as it stands now
#   concierge_agent_rule_revisions  every version it has ever had
#
# The subject keys are deliberately NULLABLE here — and only here. A rule may be
# agent-wide ("never promise a delivery date"), segment-wide ("for EU accounts,
# cite the DPA"), or specific to one account. +agent_slug+ is NOT NULL like
# everywhere else: an instruction about how to behave belongs to exactly one
# business function, and there is no shared namespace for rules on purpose
# (§10.3's `_shared` is for facts, and a rule leaking across agents is the
# cross-function contamination the whole phase exists to prevent).
class CreateConciergeAgentRules < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_agent_rules do |t|
      # Scope. agent_slug is required; the subject keys are not (see above).
      t.string :agent_slug,   null: false
      t.string :subject_type
      t.string :subject_id
      t.string :segment

      # The instruction bullet itself — one concern, injected into the Playbook
      # section of the prompt.
      t.text   :body, null: false

      # proposed -> active -> deprecated, plus `rejected` for a proposal a human
      # declined. A declined proposal was never in force, so recording it as
      # "deprecated" would lie in the audit trail.
      t.string  :state,   null: false, default: "proposed"
      t.integer :version, null: false, default: 1

      # The rule that replaced this one — the consolidation trail.
      t.bigint :superseded_by_id

      # Where the rule came from: the takeover/handoff, the operator, the run, a
      # Slack message, or "authored" by hand. Serialized JSON so a host can carry
      # its own references (a case id, a ticket) without a migration.
      t.text :provenance

      # Optional machine-checkable condition. With enforcement: "guard" this
      # graduates the rule from "instruction the model should follow" to
      # "invariant the engine checks" (§10.2, wired into execution by §10.6).
      t.text   :predicate
      t.string :enforcement, null: false, default: "advisory"

      # Who drafted it, who tapped it live. Activation requires a human approver
      # who is not the author: an agent may never promote its own rule.
      t.string :author
      t.string :approver

      t.datetime :proposed_at
      t.datetime :activated_at
      t.datetime :deprecated_at

      # The weekly "dreaming" job proposes retirements; it never performs them.
      # These two columns are that proposal, with its evidence attached.
      t.datetime :deprecation_proposed_at
      t.text     :deprecation_evidence

      t.timestamps
    end

    # The read path: "every active rule in force for this (agent, account)".
    add_index :concierge_agent_rules,
      [ :agent_slug, :state, :subject_type, :subject_id ],
      name: "index_concierge_agent_rules_on_scope_and_state"
    add_index :concierge_agent_rules, :superseded_by_id,
      name: "index_concierge_agent_rules_on_superseded_by"

    create_table :concierge_agent_rule_revisions do |t|
      t.bigint  :agent_rule_id, null: false
      t.integer :version,       null: false
      t.text    :body
      t.string  :state
      t.text    :predicate
      t.string  :enforcement
      t.string  :actor
      t.string  :note
      t.datetime :created_at, null: false
    end

    # Not unique: a state transition records a revision without bumping the
    # version, because the *instruction* did not change.
    add_index :concierge_agent_rule_revisions, [ :agent_rule_id, :version ],
      name: "index_concierge_agent_rule_revisions_on_rule_and_version"
  end
end
