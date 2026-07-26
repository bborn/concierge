# This migration comes from concierge (originally 20260101000019)
# The column that says "an executor has this and has not reported back" was named
# for the only path that stamped it (design §10.7). Both paths stamp it now.
#
# `execution_retry_queued_at` arrived with `ApprovalIntake.retry_execution(execute:
# false)`, because a retry *erases* the failure it replaces: without a marker the
# row read "approved, nothing wrong" while the diagnostic an operator had been
# looking at was gone. A first execution handed to `Concierge::ProposalExecutionJob`
# loses nothing, so it was left unstamped — and `/concierge/admin/proposals`, which
# is not the caller that queued anything, could not tell it apart from an approval
# nobody dispatched at all.
#
# The fact both paths need on the row is the same fact, so it is one column and the
# name says only what is true of both: an execution is queued, and whatever runs it
# clears this when it has an outcome to report. Renaming rather than adding a second
# column, because two columns meaning "queued" is how a screen ends up reading one
# and missing the other.
class RenameExecutionRetryQueuedAtToExecutionQueuedAt < ActiveRecord::Migration[7.1]
  def change
    rename_column :concierge_agent_proposals, :execution_retry_queued_at, :execution_queued_at
  end
end
