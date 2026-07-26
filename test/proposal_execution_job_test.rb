require "test_helper"

module Concierge
  # The job that performs an approved proposal out of band (design §10.7). It is
  # the *only* thing in the engine that executes without a caller waiting, so the
  # properties that matter are: it holds no policy of its own, it re-enters
  # Proposal::Execute (which re-checks all six refusals at the moment it runs),
  # and nothing it does to Slack afterwards can fail the execution or cause a
  # retry of it.
  class ProposalExecutionJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      Concierge::Test.configure_agents!
      @transport = Concierge::Test.configure_slack!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "user@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @scope   = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

      Concierge.configure do |c|
        c.proposals do
          execute("record.plan_change") { |proposal, scope| scope.subject.to_model.update!(plan: proposal.action_arguments[:to]) }
          precondition("record.plan_change") { |scope| { "plan" => scope.subject[:plan] } }
        end
      end
    end

    test "it performs an approved proposal and records who authorized it" do
      row = approved

      assert_equal :executed, Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")

      row.reload
      assert_equal "executed", row.state
      assert_equal "sam@acme.test", row.executed_by
      assert_equal "enterprise", @tenant.reload.plan
    end

    test "it executes from the row and refuses anything that is not approved" do
      row = propose

      assert_equal :not_approved, Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")
      assert_equal "proposed", row.reload.state
      assert_equal "pro", @tenant.reload.plan
    end

    test "running twice performs the action once" do
      # ActiveJob may retry, and the split means it can. Execute claims the row
      # with a conditional UPDATE, so at-most-once survives the queue.
      row = approved

      first  = Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")
      second = Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")

      assert_equal :executed, first
      assert_equal :already_executed, second
    end

    test "a proposal deleted between the click and the job is not an error" do
      row = approved
      id  = row.id
      row.destroy!

      assert_nil Concierge::ProposalExecutionJob.perform_now(id, by: "sam@acme.test")
    end

    test "it redraws the card with what actually happened" do
      row  = approved
      card = Concierge::SlackCard.find_by(agent_proposal_id: row.id)

      Concierge::ProposalExecutionJob.perform_now(
        row.id, by: "sam@acme.test",
        slack: { "channel" => card.channel_id, "ts" => card.message_ts, "user" => "U9" }
      )

      update = @transport.last("chat.update")
      assert_match "Executed", JSON.generate(update.payload[:blocks])
      assert_equal "executed", update.proposal_states[row.id][:state]
      assert_empty @transport.calls_to("chat.postEphemeral"), "a success was reported as a refusal"
    end

    test "a refusal reaches the person who clicked, in the process that found it out" do
      row = approved
      # The world moved between the approval and the job.
      @tenant.update!(plan: "starter")
      card = Concierge::SlackCard.find_by(agent_proposal_id: row.id)

      outcome = Concierge::ProposalExecutionJob.perform_now(
        row.id, by: "sam@acme.test",
        slack: { "channel" => card.channel_id, "ts" => card.message_ts, "user" => "U9" }
      )

      assert_equal :precondition_failed, outcome
      whisper = @transport.last("chat.postEphemeral")
      assert_equal "U9", whisper.payload[:user]
      assert_match(/approved but not performed \(precondition failed\)/, whisper.payload[:text])
      assert_match(/waiting in \/concierge\/admin\/proposals/, whisper.payload[:text])
    end

    test "Slack being down afterwards does not undo, or retry, the execution" do
      # A raise here would be an ActiveJob retry of an action a human approved
      # once — the failure mode the whole seam is built to avoid.
      row  = approved
      card = Concierge::SlackCard.find_by(agent_proposal_id: row.id)
      @transport.fail_with = Concierge::Slack::ApiError.new("channel_not_found")

      assert_nothing_raised do
        Concierge::ProposalExecutionJob.perform_now(
          row.id, by: "sam@acme.test",
          slack: { "channel" => card.channel_id, "ts" => card.message_ts, "user" => "U9" }
        )
      end

      assert_equal "executed", row.reload.state
      assert_equal "enterprise", @tenant.reload.plan
    end

    test "a retry deferred to this job performs, and needs no retry_failed of its own" do
      # The half of ApprovalIntake.retry_execution(execute: false) that a surface
      # with a deadline hands over. The job carries no knowledge that this is a
      # retry, and needs none: the failure that would have refused it
      # (:execution_previously_failed) was cleared synchronously, which is the
      # point of doing that write in the request.
      row = approved
      row.update_columns(execution_error: "the billing API was down",
                         execution_failed_at: Time.current)
      Concierge::ApprovalIntake.retry_execution(row, by: "sam@acme.test", execute: false)

      assert_equal :executed, Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")

      row.reload
      assert_equal "executed", row.state
      assert_equal "enterprise", @tenant.reload.plan
      refute row.execution_retry_queued?, "the queue is still promising a retry that already ran"
    end

    test "a deferred retry that fails again records the new failure, not the old silence" do
      row = approved
      row.update_columns(execution_error: "the billing API was down",
                         execution_failed_at: Time.current)
      Concierge.configure do |c|
        c.proposals { execute("record.plan_change") { |_p, _s| raise "the billing API was down again" } }
      end
      Concierge::ApprovalIntake.retry_execution(row, by: "sam@acme.test", execute: false)

      assert_equal :failed, Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")

      row.reload
      assert_equal "approved", row.state
      assert_match(/the billing API was down again/, row.execution_error)
      refute row.execution_retry_queued?
    end

    test "with no Slack target it still executes and says nothing" do
      # The job is not a Slack job. A surface that has nowhere to report back —
      # or none at all — gets the execution and no transport calls.
      row = approved

      assert_equal :executed, Concierge::ProposalExecutionJob.perform_now(row.id, by: "sam@acme.test")
      assert_empty @transport.calls_to("chat.update")
      assert_empty @transport.calls_to("chat.postEphemeral")
    end

    private

    def propose
      Concierge::Proposal.propose(@scope, action_class: "record.plan_change",
                                          payload: { "from" => "pro", "to" => "enterprise" },
                                          idempotency_key: "plan-1")
    end

    def approved
      propose.tap do |row|
        row.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)
      end
    end
  end
end
