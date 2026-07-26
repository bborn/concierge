# What the customer said back, and what the agent answered.
#
# The engine's ChannelDelivery keeps a payload digest, not words — the delivery
# ledger is not a message store, and this change does not amend that. The host
# already kept the outbound words here because in-app delivery leaves the
# customer nothing otherwise; the inbound half of the same exchange belongs in
# exactly the same place, under exactly the same retention policy.
#
# `reply_run_id` is the pointer back to the engine's own audit row for the turn
# (Concierge::AgentRun), so "who answered this, under which agent, with which
# rules in force" is answerable from the customer-facing row rather than only
# from the operator's. Nullable: a message nobody has answered has no run.
class AddRepliesToInboxMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :inbox_messages, :reply_body,   :text
    add_column :inbox_messages, :agent_reply,  :text
    add_column :inbox_messages, :replied_at,   :datetime
    add_column :inbox_messages, :reply_run_id, :integer
  end
end
