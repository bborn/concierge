# This migration comes from concierge (originally 20260101000016)
# The idempotency key is scoped to the (Agent × Subject) pair, like every other
# key on this table (design §10.1, §10.12).
#
# §10.9 renamed the outbox and gave the new table a globally-unique index on
# `idempotency_key` alone, reasoning from "execution is exactly-once per key"
# (§10.6). But exactly-once execution is enforced on the row — Proposal::Execute
# claims it with a conditional UPDATE — not by a global lookup, so global
# uniqueness bought nothing and cost the isolation invariant: a host that derives
# a key from a domain id (`"plan-change-#{order_id}"`) without namespacing it by
# agent and subject had its second cell's proposal silently deduped away, and was
# handed a row belonging to a different agent *and* a different account.
#
# The narrower index is always satisfiable from the wider one — every existing
# key is globally distinct, so it is distinct within its pair too. The reverse is
# not true, which is why `down` refuses rather than dropping rows.
class ScopeProposalIdempotencyToThePair < ActiveRecord::Migration[7.1]
  GLOBAL = "index_concierge_agent_proposals_on_idempotency_key".freeze
  SCOPED = "index_concierge_agent_proposals_on_scope_and_idempotency_key".freeze

  def up
    remove_index :concierge_agent_proposals, name: GLOBAL
    add_index :concierge_agent_proposals,
      [ :agent_slug, :subject_type, :subject_id, :idempotency_key ],
      unique: true, name: SCOPED
  end

  def down
    if duplicate_keys.any?
      raise ActiveRecord::IrreversibleMigration,
            "cannot restore the global unique index on " \
            "concierge_agent_proposals.idempotency_key: #{duplicate_keys.size} key(s) are " \
            "now legitimately reused across (agent, subject) pairs " \
            "(#{duplicate_keys.first(3).join(', ')}). Re-key or delete those proposals first."
    end

    remove_index :concierge_agent_proposals, name: SCOPED
    add_index :concierge_agent_proposals, :idempotency_key, unique: true, name: GLOBAL
  end

  private

  def duplicate_keys
    @duplicate_keys ||= select_values(<<~SQL.squish)
      SELECT idempotency_key FROM concierge_agent_proposals
      WHERE idempotency_key IS NOT NULL
      GROUP BY idempotency_key HAVING COUNT(*) > 1
    SQL
  end
end
