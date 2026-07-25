# OutboxItem becomes AgentProposal (design §10.6, §10.9). The old table staged
# exactly one action class — an outbound message, and only when the global
# +draft_and_review+ boolean was on. The new one stages *any* action class an
# agent may propose but not perform on its own.
#
# The shape change is body/channel/kind -> action_class + payload. Those three
# columns were the arguments of the one action the table knew about; they are
# folded into the serialized payload rather than kept alongside it, because two
# places to read "what would this send?" is two places for them to disagree.
#
# §10.9 sequences this as a rename plus additive columns, with existing `pending`
# rows mapping to `action_class: "message.outreach", state: "proposed"`. The
# "default message.outreach" it mentions is realized as the **backfill value**
# rather than a column default: on a table whose whole point is arbitrary action
# classes, a column that silently fills itself in is how a mis-wired proposal
# gets to look valid.
class RenameOutboxItemsToAgentProposals < ActiveRecord::Migration[7.1]
  MESSAGE_OUTREACH = "message.outreach".freeze

  # pending -> proposed, discarded -> rejected. A discarded draft was declined by
  # a human, which is exactly what `rejected` means; `approved` already lines up.
  STATE_MAP = { "pending" => "proposed", "discarded" => "rejected" }.freeze

  # A local model so the backfill can write JSON. The engine's own AgentProposal
  # must not be used here — it validates against the *finished* schema, and a
  # migration that depends on runtime code breaks the moment that code moves on.
  class Row < ActiveRecord::Base
    self.table_name = "concierge_agent_proposals"
  end

  def up
    rename_table :concierge_outbox_items, :concierge_agent_proposals
    add_proposal_columns
    backfill_forward
    Row.reset_column_information

    change_column_null    :concierge_agent_proposals, :action_class, false
    change_column_null    :concierge_agent_proposals, :gate, false
    change_column_default :concierge_agent_proposals, :state, from: "pending", to: "proposed"
    remove_column :concierge_agent_proposals, :body
    remove_column :concierge_agent_proposals, :channel
    remove_column :concierge_agent_proposals, :kind

    reindex
  end

  def down
    restore_indexes
    add_column :concierge_agent_proposals, :body,    :text
    add_column :concierge_agent_proposals, :channel, :string
    add_column :concierge_agent_proposals, :kind,    :string, null: false, default: "outreach"
    Row.reset_column_information
    backfill_backward

    change_column_default :concierge_agent_proposals, :state, from: "proposed", to: "pending"
    proposal_columns.each { |name, _type| remove_column :concierge_agent_proposals, name }
    rename_table :concierge_agent_proposals, :concierge_outbox_items
  end

  private

  # Every column §10.6's table needs, plus the four this implementation adds and
  # why:
  #   executed_by            who performed a :human_execution action (money)
  #   rejected_by/_reason    §2.5 — a rejection without a reason is not a decision,
  #                          and a column holding "whoever last touched this" would
  #                          make every audit query ask which way they decided
  #   corrected_*            §10.7's edit-then-approve, with the agent's original
  #                          draft kept so "what did the human change" stays
  #                          answerable
  #   execution_error/_at    a refused or failed execution, kept on the row so an
  #                          operator sees *why* instead of a silent non-event
  def proposal_columns
    [
      [ :action_class,        :string ],
      [ :payload,             :text ],
      [ :gate,                :string ],
      [ :created_by,          :string ],
      [ :approved_by,         :string ],
      [ :rejected_by,         :string ],
      [ :executed_by,         :string ],
      [ :rejected_reason,     :text ],
      [ :idempotency_key,     :string ],
      [ :precondition_digest, :string ],
      [ :rule_ids_applied,    :text ],
      [ :agent_run_id,        :bigint ],
      [ :corrected_by,        :string ],
      [ :corrected_at,        :datetime ],
      [ :original_payload,    :text ],
      [ :execution_error,     :text ],
      [ :execution_failed_at, :datetime ],
      [ :proposed_at,         :datetime ],
      [ :approved_at,         :datetime ],
      [ :rejected_at,         :datetime ],
      [ :executed_at,         :datetime ],
      [ :expires_at,          :datetime ]
    ]
  end

  def add_proposal_columns
    proposal_columns.each do |name, type|
      add_column :concierge_agent_proposals, name, type
    end
  end

  # Existing rows were staged by the one mechanism that existed, so their gate is
  # :human_approval and their proposer is the agent that drafted them. The
  # idempotency key is minted per row: it exists so an approved action executes
  # exactly once, and rows that predate it have never executed at all.
  def backfill_forward
    Row.reset_column_information
    Row.where(action_class: nil).find_each do |row|
      row.update_columns(
        action_class:     MESSAGE_OUTREACH,
        payload:          JSON.dump({ "body" => row.body, "channel" => row.channel,
                                      "kind" => row.kind }.compact),
        gate:             "human_approval",
        state:            STATE_MAP.fetch(row.state, row.state),
        created_by:       "agent:#{row.agent_slug}",
        idempotency_key:  SecureRandom.hex(16),
        proposed_at:      row.created_at,
        approved_at:      (row.updated_at if row.state == "approved"),
        rejected_at:      (row.updated_at if row.state == "discarded")
      )
    end
  end

  def backfill_backward
    reverse_states = STATE_MAP.invert
    Row.find_each do |row|
      payload = row.payload.present? ? JSON.parse(row.payload) : {}
      row.update_columns(
        body:    payload["body"],
        channel: payload["channel"],
        kind:    payload["kind"] || "outreach",
        state:   reverse_states.fetch(row.state, row.state)
      )
    end
  end

  def reindex
    remove_index :concierge_agent_proposals, name: "index_concierge_outbox_on_scope_and_state"
    add_index :concierge_agent_proposals,
      [ :agent_slug, :subject_type, :subject_id, :state ],
      name: "index_concierge_agent_proposals_on_scope_and_state"

    # Exactly-once execution rests on this being unique: two rows sharing a key
    # would be two chances to perform one action.
    add_index :concierge_agent_proposals, :idempotency_key,
      unique: true, name: "index_concierge_agent_proposals_on_idempotency_key"

    # The expiry sweep's only query: proposals still waiting, past their date.
    add_index :concierge_agent_proposals, [ :state, :expires_at ],
      name: "index_concierge_agent_proposals_on_state_and_expiry"
  end

  def restore_indexes
    remove_index :concierge_agent_proposals, name: "index_concierge_agent_proposals_on_state_and_expiry"
    remove_index :concierge_agent_proposals, name: "index_concierge_agent_proposals_on_idempotency_key"
    remove_index :concierge_agent_proposals, name: "index_concierge_agent_proposals_on_scope_and_state"
    add_index :concierge_agent_proposals,
      [ :agent_slug, :subject_type, :subject_id, :state ],
      name: "index_concierge_outbox_on_scope_and_state"
  end
end
