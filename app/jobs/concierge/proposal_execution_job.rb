module Concierge
  # Performs an already-approved proposal out of band (design §10.7).
  #
  # Why this exists at all: **a surface can have a deadline, and an executor
  # cannot promise to meet it.** Slack answers an interactivity POST with an error
  # if the endpoint takes more than about three seconds, so a host executor that
  # calls a payment provider — the exact action class this whole seam exists to
  # gate — would make Slack tell the operator their decision failed, for a
  # decision that landed *and executed*. The row would be right and the human
  # would be told it was wrong, which is the one confusion §10.7 is built to
  # prevent.
  #
  # So the ordering splits across the request boundary, and only there:
  #
  #   in the request   1. verify the signature
  #                    2. write the decision to the proposal row  (synchronous — it *is* the record)
  #                    3. enqueue this job
  #                    4. redraw the card as "approved, queued to be performed"
  #   in this job      5. Proposal::Execute
  #                    6. redraw the card with what actually happened
  #
  # Step 2 stays in the request on purpose. Everything an operator is answerable
  # for — who approved, when — is durable before Slack is answered; only the
  # *doing* is deferred. And this job holds no policy: it re-enters
  # Proposal::Execute, which reads the approved row and re-checks all six refusals
  # (expiry, kill switch, precondition, guard rules...) at the moment it runs,
  # which is later than it used to be and therefore more correct, not less.
  #
  # Retries are ActiveJob's and are safe: Execute claims the row with a
  # conditional UPDATE, so a job that runs twice performs the action once.
  class ProposalExecutionJob < ApplicationJob
    queue_as :default

    # +by+ is the human who approved, carried across the process boundary so the
    # executed row still names someone answerable. +slack+, when present, is where
    # to report back — the surface that deferred says how to reach the person who
    # is waiting.
    def perform(proposal_id, by: nil, slack: nil)
      proposal = AgentProposal.find_by(id: proposal_id)
      # A proposal deleted between the click and this job is not an error worth
      # retrying: there is no row to execute from, and Execute would refuse anyway.
      return unless proposal

      outcome = Proposal::Execute.call(proposal, by: by)
      Slack::ExecutionReport.call(proposal.reload, outcome, **report_target(slack)) if slack.present?
      outcome
    end

    private

    def report_target(slack)
      slack = slack.to_h.transform_keys(&:to_s)
      { channel: slack["channel"], ts: slack["ts"], user: slack["user"] }
    end
  end
end
