require "test_helper"

module Concierge
  # Execution (design §10.6): the six refusals between an approved row and the
  # action, and the one guarantee — exactly once.
  #
  # This is where §10.8's boundary is drawn: the engine establishes that an action
  # is *allowed to reach an executor*. Whether the action itself is legal is the
  # host executor's own question, asked again on its own terms.
  class ProposalExecuteTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
      @performed = []
    end

    test "execution reads an approved row — a proposed one is never performed" do
      proposal = host_proposal

      assert_equal :not_approved, Proposal::Execute.call(proposal)
      assert_empty @performed
      assert proposal.reload.proposed?
    end

    test "a rejected or expired row is never performed either" do
      rejected = host_proposal
      ApprovalIntake.reject(rejected, by: "sam@acme.test", reason: "not now")
      assert_equal :not_approved, Proposal::Execute.call(rejected)

      expired = host_proposal
      expired.update_columns(state: "approved", approved_by: "sam@acme.test",
                             approved_at: Time.current, expires_at: 1.hour.ago)
      assert_equal :expired, Proposal::Execute.call(expired)
      assert_empty @performed
    end

    test "approving dispatches to the executor registered for the action class" do
      register_host_executor
      proposal = host_proposal

      assert_equal :executed, ApprovalIntake.approve(proposal, by: "sam@acme.test")

      assert_equal [ { field: "plan", to: "enterprise" } ], @performed
      assert proposal.reload.executed?
      assert_equal "sam@acme.test", proposal.approved_by
      assert_equal "sam@acme.test", proposal.executed_by
      assert proposal.executed_at.present?
    end

    test "the executor is handed the resolved scope, never a raw id to look up" do
      seen = nil
      Concierge.configure { |c| c.proposals { execute("record.update") { |_p, scope| seen = scope } } }
      ApprovalIntake.approve(host_proposal, by: "sam@acme.test")

      assert_equal @billing, seen
      assert_equal @tenant, seen.subject.to_model
    end

    test "execution is exactly once per idempotency key" do
      register_host_executor
      proposal = host_proposal
      ApprovalIntake.approve(proposal, by: "sam@acme.test")

      assert_equal :already_executed, Proposal::Execute.call(proposal)
      assert_equal :already_executed, Proposal::Execute.call(proposal.reload)
      assert_equal 1, @performed.size
    end

    test "two concurrent executions of one approved row perform it once" do
      register_host_executor
      proposal = host_proposal
      proposal.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)

      # Two callers holding their own copy of the same row — a double-clicked
      # Approve button, or an at-least-once job delivered twice.
      first  = AgentProposal.find(proposal.id)
      second = AgentProposal.find(proposal.id)

      outcomes = [ Proposal::Execute.call(first), Proposal::Execute.call(second) ]

      assert_equal [ :executed, :already_executed ], outcomes
      assert_equal 1, @performed.size
    end

    test "a :human_execution proposal is never performed by the engine" do
      register_host_executor("money.refund")
      proposal = Proposal.propose(@billing, action_class: "money.refund",
                                            payload: { order_id: 42, amount_cents: 2500 })

      assert_equal :approved, ApprovalIntake.approve(proposal, by: "sam@acme.test")
      assert_empty @performed, "money must not be moved by the engine"
      assert proposal.reload.approved?
      refute proposal.executed?

      # ...and calling Execute directly refuses too, not just the approval path.
      assert_equal :human_execution_required, Proposal::Execute.call(proposal)
      assert_empty @performed
    end

    test "a human records the execution they performed themselves" do
      proposal = Proposal.propose(@billing, action_class: "money.refund", payload: { order_id: 42 })
      ApprovalIntake.approve(proposal, by: "sam@acme.test")

      assert_equal :executed, ApprovalIntake.record_execution(proposal, by: "sam@acme.test")
      assert_equal "sam@acme.test", proposal.reload.executed_by
    end

    test "an execution cannot be recorded for something nobody approved" do
      proposal = Proposal.propose(@billing, action_class: "money.refund")

      assert_raises(Proposal::GateError) { ApprovalIntake.record_execution(proposal, by: "sam@acme.test") }
      refute proposal.reload.executed?
    end

    test "the kill switch is read again at execution, not only at run start" do
      register_host_executor
      proposal = host_proposal
      proposal.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)

      Concierge.configure { |c| c.agent(:billing) { enabled false } }

      assert_equal :agent_disabled, Proposal::Execute.call(proposal)
      assert_empty @performed, "halting a function must stop its approved work too"
      assert proposal.reload.approved?
    end

    test "a precondition that moved between propose and execute fails the execution" do
      register_host_executor
      Concierge.configure do |c|
        c.proposals { precondition("record.update") { |scope| { plan: scope.subject[:plan] } } }
      end
      proposal = host_proposal
      assert proposal.precondition_digest.present?

      @tenant.update!(plan: "free")

      assert_equal :precondition_failed, ApprovalIntake.approve(proposal, by: "sam@acme.test")
      assert_empty @performed
      assert proposal.reload.approved?, "the human's decision stands; the action did not happen"
      assert_match(/has changed since it was drafted/, proposal.execution_error)
    end

    test "an unchanged precondition executes normally" do
      register_host_executor
      Concierge.configure do |c|
        c.proposals { precondition("record.update") { |scope| { plan: scope.subject[:plan] } } }
      end

      assert_equal :executed, ApprovalIntake.approve(host_proposal, by: "sam@acme.test")
      assert_equal 1, @performed.size
    end

    test "an action class with no declared precondition says so rather than faking a check" do
      register_host_executor
      proposal = host_proposal

      assert_nil proposal.precondition_digest
      assert_equal :executed, ApprovalIntake.approve(proposal, by: "sam@acme.test")
    end

    test "a guard rule activated after the draft still blocks its execution" do
      proposal = Outreach.deliver(Result.new(reply_text: "we guarantee it ships Friday"),
                                  @billing, channel: :in_app)
      assert_equal :drafted, proposal
      staged = AgentProposal.sole

      rule = Rules.propose(@billing, body: "Never put the word guarantee in a customer email.",
                                     enforcement: "guard", author: "a",
                                     predicate: { "action_class" => Authority::MESSAGE_OUTREACH,
                                                  "deny_when" => { "body" => { "matches" => "guarantee" } } })
      Rules.activate!(rule, by: "sam@acme.test")

      assert_equal :blocked_by_rule, ApprovalIntake.approve(staged, by: "sam@acme.test")
      assert_equal 0, ChannelDelivery.count
      assert_match(/guard rule/, staged.reload.execution_error)
    end

    test "the built-in message executor delivers and audits under the proposing agent" do
      Outreach.deliver(Result.new(reply_text: "your card expires soon"), @billing, channel: :in_app)
      staged = AgentProposal.sole

      assert_equal :executed, ApprovalIntake.approve(staged, by: "sam@acme.test")

      delivery = ChannelDelivery.sole
      assert_equal "billing", delivery.agent_slug, "an approved send is audited to the agent that drafted it"
      assert_equal "in_app",  delivery.channel
      assert_includes InAppInbox.messages.map { |m| m[:body] }, "your card expires soon"
      assert delivery.unsubscribe_token.present?
    end

    test "a customer who opted out between draft and approval is not messaged" do
      # The one precondition the engine declares for itself: the customer's own
      # standing instruction about being contacted.
      Outreach.deliver(Result.new(reply_text: "your card expires soon"), @billing, channel: :in_app)
      staged = AgentProposal.sole
      assert staged.precondition_digest.present?

      OutreachPreference.for(@subject).update!(opted_out: true)

      assert_equal :precondition_failed, ApprovalIntake.approve(staged, by: "sam@acme.test")
      assert_equal 0, ChannelDelivery.count
      assert_empty InAppInbox.messages
    end

    test "an action class with no executor refuses loudly and performs nothing" do
      proposal = Proposal.propose(@billing, action_class: "record.update")
      proposal.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)

      assert_equal :no_executor, Proposal::Execute.call(proposal)
      refute proposal.reload.executed?
    end

    test "an executor that raises leaves the row un-executed with the reason on it" do
      Concierge.configure do |c|
        c.proposals { execute("record.update") { |_p, _s| raise ArgumentError, "order is closed" } }
      end
      proposal = host_proposal

      assert_equal :failed, ApprovalIntake.approve(proposal, by: "sam@acme.test")

      proposal.reload
      refute proposal.executed?
      assert_equal "approved", proposal.state
      assert_match(/ArgumentError: order is closed/, proposal.execution_error)
      assert proposal.execution_failed?
    end

    test "a failed execution is not retried automatically — a human clears it" do
      attempts = 0
      Concierge.configure do |c|
        c.proposals do
          execute("record.update") do |_p, _s|
            attempts += 1
            raise "the API was down" if attempts == 1

            true
          end
        end
      end
      proposal = host_proposal
      assert_equal :failed, ApprovalIntake.approve(proposal, by: "sam@acme.test")

      # One approved action must not become two just because the first attempt
      # timed out, so nothing re-attempts on its own.
      assert_equal :execution_previously_failed, Proposal::Execute.call(proposal.reload)
      assert_equal 1, attempts

      assert_equal :executed, ApprovalIntake.retry_execution(proposal, by: "sam@acme.test")
      assert_equal 2, attempts
      assert proposal.reload.executed?
      assert_nil proposal.execution_error
    end

    test "a refusal ends a queued retry even when it writes nothing else to the row" do
      # Half the six refusals return without touching the row — no executor, a
      # halted agent, a row someone else already executed. A queued-retry stamp
      # that survived one of them would leave the admin queue promising, forever,
      # that something is about to happen.
      proposal = Proposal.propose(@billing, action_class: "record.update")
      proposal.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)
      ApprovalIntake.retry_execution(proposal, by: "sam@acme.test", execute: false)
      assert proposal.reload.execution_queued?

      assert_equal :no_executor, Proposal::Execute.call(proposal)

      refute proposal.reload.execution_queued?
    end

    test "an executor may be registered by prefix, and the most specific one wins" do
      calls = []
      Concierge.configure do |c|
        c.proposals do
          execute("record.*")      { |_p, _s| calls << :wide }
          execute("record.update") { |_p, _s| calls << :exact }
          execute("*")             { |_p, _s| calls << :catch_all }
        end
      end

      ApprovalIntake.approve(host_proposal, by: "sam@acme.test")
      ApprovalIntake.approve(Proposal.propose(@billing, action_class: "record.delete"),
                             by: "sam@acme.test")
      ApprovalIntake.approve(Proposal.propose(@billing, action_class: "crm.sync"),
                             by: "sam@acme.test")

      assert_equal [ :exact, :wide, :catch_all ], calls
    end

    test "a host can override the engine's own message executor" do
      sent = []
      Concierge.configure { |c| c.proposals { execute(Authority::MESSAGE_OUTREACH) { |p, _s| sent << p.body } } }
      Outreach.deliver(Result.new(reply_text: "your card expires soon"), @billing, channel: :in_app)

      ApprovalIntake.approve(AgentProposal.sole, by: "sam@acme.test")

      assert_equal [ "your card expires soon" ], sent
      assert_equal 0, ChannelDelivery.count
    end

    test "a proposal whose agent left the config is inert data, not a crash" do
      register_host_executor
      proposal = host_proposal
      proposal.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)
      proposal.update_columns(agent_slug: "an-agent-that-was-removed")

      assert_equal :unresolved_scope, Proposal::Execute.call(proposal.reload)
      assert_empty @performed
    end

    private

    def host_proposal(action_class = "record.update")
      Proposal.propose(@billing, action_class: action_class,
                                 payload: { field: "plan", to: "enterprise" })
    end

    def register_host_executor(action_class = "record.update")
      performed = @performed
      Concierge.configure do |c|
        c.proposals { execute(action_class) { |proposal, _scope| performed << proposal.action_arguments } }
      end
    end
  end
end
