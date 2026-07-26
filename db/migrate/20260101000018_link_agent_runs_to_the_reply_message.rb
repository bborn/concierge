# A run row records what the agent was told (the rule pins) and what it says it
# did (the citation) — and nothing about what it actually said. Reading the reply
# is the only way a human can tell a turn that complied and cited from one that
# contradicted the rule and cited it anyway (design §10.4, turns B and C); the
# two record identically, and the engine cannot tell them apart.
#
# `chat_id` alone is not enough to check one: it names a thread of many turns,
# not the turn. This adds the pointer to the assistant Message the host persisted
# for *this* run, so the operator screen can read that one reply back.
#
# A pointer, deliberately, not a copy. The reply is customer-facing text, and
# §10.12 leaves how long that is kept to the host: provenance rows are pruned on
# a compliance cadence, and duplicating a customer's conversation into them would
# be the engine making a privacy and retention decision on the host's behalf.
# When the host prunes its chats, the link goes dead and the screen says so.
class LinkAgentRunsToTheReplyMessage < ActiveRecord::Migration[7.1]
  def change
    add_column :concierge_agent_runs, :message_id, :bigint
  end
end
