# This migration comes from concierge (originally 20260101000015)
# The Slack side of a proposal (design §10.7). Slack is the remote control;
# Postgres is the record — so this table holds only what is needed to *address*
# a card that was posted, never the decision itself. The decision lives on
# concierge_agent_proposals, which is why a Slack outage costs an operator
# convenience and not authority: /concierge/admin/proposals is the same queue.
#
# Keyed by the (Agent × Subject) pair like every other per-agent table, for three
# reasons that all matter here:
#
#   * **one channel per agent** — the channel id is resolved from the agent, and
#     a card that leaked into another agent's channel would be a disclosure bug,
#     not a cosmetic one;
#   * **one thread per case** — the case is the (agent, account) pair, so the
#     thread that Acme's billing history hangs off is found by scope and can
#     never be the thread CSM is posting into;
#   * **per-agent daily card caps** — the anti-noise budget is per agent, so the
#     count that enforces it is a scoped query like every other.
#
# `state` records what happened to the *card*, not the proposal:
#   posted      the card is in Slack and addressable (channel_id + message_ts)
#   suppressed  the agent hit its daily cap; the proposal is still in the queue
#   failed      Slack refused or was unreachable; ditto
class CreateConciergeSlackCards < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_slack_cards do |t|
      t.string :agent_slug,   null: false
      t.string :subject_type, null: false
      t.string :subject_id,   null: false

      t.bigint :agent_proposal_id, null: false

      t.string :channel_id
      t.string :message_ts
      t.string :thread_ts

      t.string   :state, null: false, default: "posted"
      t.datetime :posted_at
      t.text     :error

      t.timestamps
    end

    # One card per proposal: a second card for the same proposal is two places to
    # click Approve on one row, and the loser's card would go stale silently.
    add_index :concierge_slack_cards, :agent_proposal_id, unique: true

    add_index :concierge_slack_cards,
      [ :agent_slug, :subject_type, :subject_id, :created_at ],
      name: "index_concierge_slack_cards_on_scope_and_recency"

    # The daily cap counts posted cards per agent per day.
    add_index :concierge_slack_cards, [ :agent_slug, :posted_at ],
      name: "index_concierge_slack_cards_on_agent_and_posted_at"

    # How an inbound payload finds its way back to a case: Slack hands us a
    # channel + message (or thread) timestamp and nothing else.
    add_index :concierge_slack_cards, [ :channel_id, :message_ts ],
      name: "index_concierge_slack_cards_on_message"
    add_index :concierge_slack_cards, [ :channel_id, :thread_ts ],
      name: "index_concierge_slack_cards_on_thread"
  end
end
