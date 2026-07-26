require "test_helper"

module Concierge
  # The inbound approval seam (design §10.7). Delivery and approval-intake are two
  # seams on purpose: a channel is outbound-only, and the click that comes back is
  # not a delivery concern. These assert the seam holds all the policy, so a
  # surface — the admin screen, step 4's Slack adapter — can hold none.
  class ApprovalIntakeTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    end

    test "approve transitions the row and records who authorized it" do
      proposal = staged_message

      assert_equal :executed, ApprovalIntake.approve(proposal, by: "sam@acme.test")

      proposal.reload
      assert_equal "sam@acme.test", proposal.approved_by
      assert proposal.approved_at.present?
      assert proposal.executed?
    end

    test "approve can transition without executing, for a surface that defers it" do
      proposal = staged_message

      assert_equal :approved, ApprovalIntake.approve(proposal, by: "sam@acme.test", execute: false)

      assert proposal.reload.approved?
      assert_equal 0, ChannelDelivery.count
      # ...and the approved row is what execution later reads. There is no second
      # path that skips it.
      assert_equal :executed, Proposal::Execute.call(proposal)
      assert_equal 1, ChannelDelivery.count
    end

    test "correct edits the agent's draft, keeps the original, and approves the edit" do
      proposal = staged_message

      ApprovalIntake.correct(proposal, by: "sam@acme.test",
                                       payload: { body: "Your card expires before the 1st — update it here." })

      proposal.reload
      assert_equal "Your card expires before the 1st — update it here.", proposal.body
      assert_equal "your card expires soon", proposal.original_payload["body"]
      assert_equal "sam@acme.test", proposal.corrected_by
      assert proposal.corrected?
      assert proposal.executed?

      assert_includes InAppInbox.messages.map { |m| m[:body] },
                      "Your card expires before the 1st — update it here."
    end

    test "a correction keeps the rest of the payload rather than replacing it" do
      proposal = staged_message

      ApprovalIntake.correct(proposal, by: "sam@acme.test", payload: { body: "edited" }, execute: false)

      assert_equal "in_app",   proposal.reload.channel
      assert_equal "outreach", proposal.kind
    end

    test "correcting re-baselines what the execution re-validates against" do
      # The human just looked at the world and decided; the digest should reflect
      # what *they* saw, not what the agent saw an hour earlier.
      proposal = staged_message
      original = proposal.precondition_digest
      OutreachPreference.for(@subject).update!(frequency: "less")

      ApprovalIntake.correct(proposal, by: "sam@acme.test", payload: { body: "edited" })

      refute_equal original, proposal.reload.precondition_digest
      assert proposal.executed?, "the correction was made against current state, so it executes"
    end

    test "correct is still maker-checked — an agent cannot edit-then-approve" do
      proposal = staged_message

      assert_raises(Proposal::GateError) do
        ApprovalIntake.correct(proposal, by: Rules.agent_actor(:billing), payload: { body: "mine now" })
      end
      assert_equal "your card expires soon", proposal.reload.body
    end

    test "the seam refuses to decide anything that is not open" do
      proposal = staged_message
      ApprovalIntake.approve(proposal, by: "sam@acme.test")

      %w[approve reject correct].each do |action|
        assert_raises(Proposal::GateError, "#{action} touched a decided proposal") do
          case action
          when "approve" then ApprovalIntake.approve(proposal, by: "other@acme.test")
          when "reject"  then ApprovalIntake.reject(proposal, by: "other@acme.test", reason: "no")
          when "correct" then ApprovalIntake.correct(proposal, by: "other@acme.test", payload: { body: "x" })
          end
        end
      end
    end

    test "rejecting leaves nothing delivered and nothing executable" do
      proposal = staged_message

      ApprovalIntake.reject(proposal, by: "sam@acme.test", reason: "we already emailed them today")

      assert_equal 0, ChannelDelivery.count
      refute proposal.reload.executable?
      assert_equal :not_approved, Proposal::Execute.call(proposal)
    end

    test "retrying is a human act, with an actor, like every other transition" do
      proposal = staged_message
      proposal.update_columns(state: "approved", approved_by: "sam@acme.test",
                              approved_at: Time.current, execution_error: "boom",
                              execution_failed_at: Time.current)

      assert_raises(Proposal::GateError) { ApprovalIntake.retry_execution(proposal, by: "") }
      assert_raises(Proposal::GateError) do
        ApprovalIntake.retry_execution(proposal, by: Rules.agent_actor(:billing))
      end
    end

    test "retry can clear the failure without executing, for a surface that defers it" do
      # §10.7's opt-out, which retry did not have: it was the one path left that
      # re-entered Proposal::Execute synchronously with no way out, so the first
      # Retry button on a Slack card would have hit the three-second wall the
      # Approve button no longer hits.
      proposal = failed_execution

      assert_equal :approved, ApprovalIntake.retry_execution(proposal, by: "sam@acme.test",
                                                                       execute: false)

      proposal.reload
      # The clear is the record of the human's decision, so it is durable before
      # the surface answers — exactly like the approval it mirrors.
      assert_nil proposal.execution_error
      refute proposal.execution_failed?
      # ...and nothing was performed.
      assert_equal 0, ChannelDelivery.count
      assert proposal.approved?
    end

    test "a deferred retry says so on the row, because it erased the failure that was there" do
      # "approved, no error, nothing failed" is what an approval nobody has
      # attempted looks like. A retry that cleared a failure and queued the doing
      # must not be indistinguishable from one, or the only diagnostic an operator
      # had is gone with nothing in its place.
      proposal = failed_execution

      ApprovalIntake.retry_execution(proposal, by: "sam@acme.test", execute: false)

      assert proposal.reload.execution_retry_queued?
    end

    test "retrying inline stays the default, and leaves no queued-retry stamp behind" do
      proposal = failed_execution

      assert_equal :executed, ApprovalIntake.retry_execution(proposal, by: "sam@acme.test")

      proposal.reload
      assert proposal.executed?
      assert_equal 1, ChannelDelivery.count
      refute proposal.execution_retry_queued?,
             "an execution that already happened is not still queued"
    end

    private

    # Where a retry starts from: approved, attempted, and the attempt recorded a
    # failure a human has now looked at.
    def failed_execution
      staged_message.tap do |proposal|
        proposal.update_columns(state: "approved", approved_by: "sam@acme.test",
                                approved_at: Time.current,
                                execution_error: "Net::ReadTimeout: the API did not answer",
                                execution_failed_at: Time.current)
      end
    end

    def staged_message
      Outreach.deliver(Result.new(reply_text: "your card expires soon"), @billing, channel: :in_app)
      AgentProposal.sole
    end
  end
end
