require "test_helper"

module Concierge
  # The proposal object and its gate (design §10.6). OutboxItem staged one action
  # class — an outbound message — and only when a global boolean was on. These
  # assert the generalized shape: any action class, a gate snapshotted from the
  # agent's authority envelope, maker-checker, and an idempotency key.
  class ProposalTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    end

    test "a proposal carries an arbitrary action class and its serialized payload" do
      proposal = Proposal.propose(@billing, action_class: "record.update",
                                            payload: { field: "plan", to: "enterprise" })

      assert_equal "record.update", proposal.action_class
      assert_equal({ "field" => "plan", "to" => "enterprise" }, proposal.payload)
      assert_equal({ field: "plan", to: "enterprise" }, proposal.action_arguments)
      assert_equal "billing", proposal.agent_slug
      assert proposal.proposed?
    end

    test "the gate is the agent's authority level for that class, snapshotted" do
      # :billing declares `default :human_approval` and `action "money.refund",
      # :human_execution`.
      assert_equal "human_approval",  Proposal.propose(@billing, action_class: "record.update").gate
      assert_equal "human_execution", Proposal.propose(@billing, action_class: "money.refund").gate
    end

    test "a snapshotted gate is not re-read from config later" do
      proposal = Proposal.propose(@billing, action_class: "money.refund")

      # A host that loosens the envelope after the fact must not retroactively
      # turn a waiting money proposal into one the engine will execute itself.
      Concierge.configure { |c| c.agent(:billing) { authority { action "money.refund", :human_approval } } }

      assert_equal "human_execution", proposal.reload.gate
      assert proposal.human_execution?
    end

    test "proposing an autonomous action refuses instead of staging a no-op" do
      # The CSM is autonomous on messages. A proposal nobody ever has to look at
      # is worse than an error: it looks like a queue entry and is not one.
      error = assert_raises(Proposal::GateError) do
        Proposal.propose(@csm, action_class: Authority::MESSAGE_OUTREACH, payload: { body: "hi" })
      end

      assert_match(/:autonomous/, error.message)
      assert_match(/execute it directly/, error.message)
      assert_equal 0, AgentProposal.count
    end

    test "the proposer is the agent, written with the prefix that can never approve" do
      proposal = Proposal.propose(@billing, action_class: "record.update")

      assert_equal "agent:billing", proposal.created_by
      assert Rules.agent_actor?(proposal.created_by)
    end

    test "maker-checker: the actor that proposed can never be the one that approves" do
      proposal = Proposal.propose(@billing, action_class: "record.update", created_by: "sam@acme.test")

      error = assert_raises(Proposal::GateError) do
        ApprovalIntake.approve(proposal, by: "sam@acme.test")
      end

      assert_match(/maker-checker/, error.message)
      assert proposal.reload.proposed?
    end

    test "maker-checker is enforced at the row too, not only at the seam" do
      # Any other write path — a console, a host's own code — must not be able to
      # do what the seam refuses.
      proposal = Proposal.propose(@billing, action_class: "record.update", created_by: "sam@acme.test")
      proposal.approved_by = "sam@acme.test"

      refute proposal.valid?
      assert_includes proposal.errors.attribute_names, :approved_by
    end

    test "an agent can never approve, whatever the surface" do
      proposal = Proposal.propose(@billing, action_class: "record.update")

      error = assert_raises(Proposal::GateError) do
        ApprovalIntake.approve(proposal, by: Rules.agent_actor(:csm))
      end

      assert_match(/never approve/, error.message)
    end

    test "approving with no actor at all refuses rather than inventing one" do
      proposal = Proposal.propose(@billing, action_class: "record.update")

      assert_raises(Proposal::GateError) { ApprovalIntake.approve(proposal, by: "") }
      assert_raises(Proposal::GateError) { ApprovalIntake.approve(proposal, by: nil) }
    end

    test "approved and rejected timestamps are mutually exclusive" do
      proposal = Proposal.propose(@billing, action_class: "record.update")
      proposal.approved_at = Time.current
      proposal.rejected_at = Time.current

      refute proposal.valid?
      assert_includes proposal.errors.attribute_names, :rejected_at
    end

    test "a rejection requires a reason" do
      proposal = Proposal.propose(@billing, action_class: "record.update")

      error = assert_raises(Proposal::GateError) do
        ApprovalIntake.reject(proposal, by: "sam@acme.test", reason: "  ")
      end
      assert_match(/needs a reason/, error.message)
      assert proposal.reload.proposed?

      ApprovalIntake.reject(proposal, by: "sam@acme.test", reason: "wrong tone for this account")

      assert proposal.reload.rejected?
      assert_equal "wrong tone for this account", proposal.rejected_reason
      assert_equal "sam@acme.test", proposal.rejected_by
      assert_nil   proposal.approved_by, "a decliner must not be recorded as an approver"
      assert_nil   proposal.approved_at
    end

    test "a rejected state cannot be written without a reason by any path" do
      proposal = Proposal.propose(@billing, action_class: "record.update")
      proposal.state = "rejected"

      refute proposal.valid?
      assert_includes proposal.errors.attribute_names, :rejected_reason
    end

    test "every proposal gets an idempotency key, and keys are unique" do
      first  = Proposal.propose(@billing, action_class: "record.update")
      second = Proposal.propose(@billing, action_class: "record.update")

      assert first.idempotency_key.present?
      refute_equal first.idempotency_key, second.idempotency_key

      duplicate = AgentProposal.new(**@billing.key, action_class: "record.update",
                                    gate: "human_approval", idempotency_key: first.idempotency_key)
      refute duplicate.valid?
    end

    test "a supplied key makes proposing idempotent instead of stacking cards" do
      first  = Proposal.propose(@billing, action_class: "record.update", idempotency_key: "invoice-4471")
      second = Proposal.propose(@billing, action_class: "record.update", idempotency_key: "invoice-4471")

      assert_equal first.id, second.id
      assert_equal 1, AgentProposal.count
    end

    test "a proposal expires only when the host asked for a TTL" do
      assert_nil Proposal.propose(@billing, action_class: "record.update").expires_at

      Concierge.config.proposal_ttl = 3.days
      proposal = Proposal.propose(@billing, action_class: "record.update")

      assert_in_delta 3.days.from_now.to_f, proposal.expires_at.to_f, 5
    end

    test "the expiry sweep retires unapproved proposals and leaves decided ones alone" do
      Concierge.config.proposal_ttl = 1.day
      stale    = Proposal.propose(@billing, action_class: "record.update")
      approved = Proposal.propose(@billing, action_class: "record.update")
      fresh    = Proposal.propose(@billing, action_class: "record.update", expires_in: 30.days)

      approved.update!(state: "approved", approved_by: "sam@acme.test", approved_at: Time.current)
      [ stale, approved ].each { |p| p.update_columns(expires_at: 2.days.ago) }

      assert_equal 1, Proposal.expire_stale!

      assert_equal "expired",  stale.reload.state
      assert_equal "approved", approved.reload.state,
                   "expiring an approved proposal would quietly reverse a human"
      assert_equal "proposed", fresh.reload.state
    end

    test "an expired proposal cannot be approved late" do
      proposal = Proposal.propose(@billing, action_class: "record.update", expires_in: 1.hour)
      proposal.update_columns(expires_at: 1.hour.ago)

      error = assert_raises(Proposal::GateError) { ApprovalIntake.approve(proposal, by: "sam@acme.test") }

      assert_match(/expired/, error.message)
      refute proposal.reload.approved?
    end

    test "a decided proposal cannot be decided twice" do
      proposal = Proposal.propose(@billing, action_class: "money.refund")
      ApprovalIntake.approve(proposal, by: "sam@acme.test")

      assert_raises(Proposal::GateError) { ApprovalIntake.approve(proposal, by: "other@acme.test") }
      assert_raises(Proposal::GateError) do
        ApprovalIntake.reject(proposal, by: "other@acme.test", reason: "changed my mind")
      end
    end

    test "a gated agent's outreach is staged as a message.outreach proposal" do
      status = Outreach.deliver(Result.new(reply_text: "your card expires soon"), @billing,
                                channel: :email)

      proposal = AgentProposal.sole
      assert_equal :drafted, status
      assert_equal Authority::MESSAGE_OUTREACH, proposal.action_class
      assert_equal "your card expires soon", proposal.body
      assert_equal "email", proposal.channel
      assert_equal "outreach", proposal.kind
      assert proposal.message?
      assert_equal 0, ChannelDelivery.count, "staging must not also send"
    end

    test "the legacy draft_and_review flag tightens the gate, not just the staging" do
      # The staging decision and the gate stamped on the row have to come from one
      # definition of "what may this agent do". Two definitions is how a proposal
      # gets staged with a gate that says the agent could have just sent it.
      Concierge.config.draft_and_review = true

      assert_equal :drafted, Outreach.deliver(Result.new(reply_text: "a nudge"), @csm, channel: :in_app)
      assert_equal "human_approval", AgentProposal.sole.gate
      assert_equal :autonomous, @csm.agent.authority.level_for(Authority::MESSAGE_OUTREACH),
                   "the declared envelope is untouched — the flag is an override, not a rewrite"
    end

    test "the legacy flag cannot loosen an agent that already gates harder" do
      Concierge.config.draft_and_review = true

      assert_equal :human_execution, @billing.agent.level_for("money.refund")
      assert_equal "human_execution", Proposal.propose(@billing, action_class: "money.refund").gate
    end

    test "a staged message carries the rules the run said it applied" do
      result = Result.new(reply_text: "your card expires soon", rule_ids_applied: [ 7, 9 ])

      Outreach.deliver(result, @billing, channel: :email)

      assert_equal [ 7, 9 ], AgentProposal.sole.rule_ids_applied
    end

    test "OutboxItem still names the same table for one release" do
      # §10.9's back-compat promise: a host's existing reads keep answering.
      Proposal.propose(@billing, action_class: Authority::MESSAGE_OUTREACH, payload: { body: "hi" })

      assert_equal AgentProposal, Concierge::OutboxItem
      assert_equal 1, Concierge::OutboxItem.pending.for_scope(@billing).count
      assert_equal "hi", Concierge::OutboxItem.for_scope(@billing).sole.body
    end

    test "a proposal notifier posts the card, and a broken one never loses it" do
      posted = []
      Concierge.config.proposal_notifier = ->(proposal) { posted << proposal.id }
      first = Proposal.propose(@billing, action_class: "record.update")
      assert_equal [ first.id ], posted

      Concierge.config.proposal_notifier = ->(_p) { raise "slack is down" }
      second = Proposal.propose(@billing, action_class: "record.update")
      assert second.persisted?
    end

    test "the payload is the single source of truth for what would happen" do
      # body/channel/kind were columns; they are derived readers now, so there is
      # no second place for them to disagree with the payload.
      refute AgentProposal.column_names.include?("body")
      refute AgentProposal.column_names.include?("channel")
      refute AgentProposal.column_names.include?("kind")
    end
  end
end
