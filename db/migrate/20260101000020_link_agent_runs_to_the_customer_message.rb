# The run row learned to point at the reply (#18) — but the online path never
# persisted the *question*, so there was nothing on the other side of it to point
# at, and the run screen said so in as many words.
#
# Now that the customer's turn is written down (Concierge::PersistentChat), this
# adds the matching pointer. A reply read on its own is barely evidence: "we can't
# offer that" is compliant or catastrophic depending entirely on what was asked.
# The pair is what an operator can actually spot-check a cited rule against.
#
# A pointer, like its twin, and for the same reason: these are the customer's own
# words in the host's tables under the host's retention policy (§10.12). When the
# host prunes, the link goes dead and the screen says so rather than showing a
# copy the host thought it had deleted.
class LinkAgentRunsToTheCustomerMessage < ActiveRecord::Migration[7.1]
  def change
    add_column :concierge_agent_runs, :prompt_message_id, :bigint
  end
end
