# This migration comes from concierge (originally 20260101000017)
# A human asked for a failed execution to be tried again, and the surface they
# asked from could not wait for it (design §10.7).
#
# `ApprovalIntake.retry_execution` clears `execution_error`/`execution_failed_at`
# — that clear *is* the record of the human's decision to try again, so it stays
# synchronous. But a surface with a deadline (a Retry button on a Slack card) then
# hands the doing to `Concierge::ProposalExecutionJob`, and between those two
# moments the row says `approved`, no error, nothing failed: identical to a
# proposal approved a second ago and never attempted. The previous failure has
# been erased and nothing has replaced it.
#
# That window is bounded by nothing. If the enqueue itself fails, or the queue is
# down, it never closes, and the only diagnostic an operator had is gone. So the
# retry is written to the row like every other thing an operator is answerable
# for, and `Proposal::Execute` clears it the moment it has an outcome to report
# instead.
class AddExecutionRetryQueuedAtToAgentProposals < ActiveRecord::Migration[7.1]
  def change
    add_column :concierge_agent_proposals, :execution_retry_queued_at, :datetime
  end
end
