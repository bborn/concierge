require "test_helper"

module Concierge
  # The outbound half of §10.7, and the two anti-noise rules that live on it (§2.6):
  # a per-agent daily card cap, and one thread per case.
  class SlackNotifierTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @transport = Concierge::Test.configure_slack!
      @acme      = subject_for("Acme")
      @globex    = subject_for("Globex")
      @billing   = Concierge::Scope.new(Concierge.config.agent(:billing), @acme)
    end

    test "proposing an action posts a card to that agent's channel" do
      row = propose(@billing)

      call = @transport.last("chat.postMessage")
      assert_equal "C0BILLING", call.payload[:channel]
      assert_match "proposal ##{row.id}", call.payload[:text]

      card = Concierge::SlackCard.sole
      assert card.posted?
      assert_equal row.id, card.agent_proposal_id
      assert_equal "billing", card.agent_slug
      assert_equal call.payload[:channel], card.channel_id
      assert card.message_ts.present?
    end

    test "an agent with no channel configured posts nothing and records nothing" do
      # A host that wired Slack up for one business function before the others: the
      # unwired one still queues normally, it just does not interrupt anybody.
      @transport = Concierge::Test.configure_slack!(channels: { csm: "C0CSM" })

      propose(@billing)

      assert_empty @transport.calls_to("chat.postMessage")
      assert_equal 0, Concierge::SlackCard.count
    end

    test "later cards for the same case reply into the case's thread" do
      first  = propose(@billing, key: "one")
      second = propose(@billing, key: "two")

      root = Concierge::SlackCard.find_by(agent_proposal_id: first.id)
      reply = Concierge::SlackCard.find_by(agent_proposal_id: second.id)

      assert_nil @transport.calls_to("chat.postMessage").first.payload[:thread_ts],
                 "the first card for a case should start the thread, not reply to one"
      assert_equal root.message_ts, @transport.calls_to("chat.postMessage").last.payload[:thread_ts]
      assert_equal root.message_ts, reply.thread_ts
    end

    test "a case thread is never shared across agents or accounts" do
      # One thread per case, where the case is the (agent, account) pair. Replying a
      # refund card into another account's thread would put one customer's business
      # in front of the wrong case.
      billing_acme   = propose(@billing, key: "a")
      billing_globex = propose(Concierge::Scope.new(Concierge.config.agent(:billing), @globex), key: "b")

      threads = [ billing_acme, billing_globex ].map do |row|
        Concierge::SlackCard.find_by(agent_proposal_id: row.id).thread_ts
      end
      assert_equal 2, threads.uniq.size, "two cases shared one thread"
    end

    test "the daily card cap suppresses the card but never the proposal" do
      @transport = Concierge::Test.configure_slack!(cap: 1)

      first  = propose(@billing, key: "one")
      capped = propose(@billing, key: "two")

      assert_equal 1, @transport.calls_to("chat.postMessage").size
      assert Concierge::SlackCard.find_by(agent_proposal_id: first.id).posted?
      assert Concierge::SlackCard.find_by(agent_proposal_id: capped.id).suppressed?

      # ...and the authority is untouched: it is still awaiting a human in the queue.
      assert capped.reload.proposed?
      assert_includes Concierge::AgentProposal.awaiting.map(&:id), capped.id
    end

    test "the cap is per agent, so one noisy function cannot mute another" do
      @transport = Concierge::Test.configure_slack!(cap: 1)
      # The CSM gates this one class so it has something to card at all; everything
      # else about it stays autonomous.
      Concierge.configure do |c|
        c.agent(:csm) { authority { action "record.plan_change", :human_approval } }
      end

      propose(@billing, key: "billing-1")
      propose(@billing, key: "billing-2")
      csm = propose(csm_scope, key: "csm-1")

      assert Concierge::SlackCard.find_by(agent_proposal_id: csm.id).posted?,
             "the CSM's first card was suppressed by billing's volume"
      assert_equal 1, Concierge::SlackCard.posted_today(:csm).count
      assert_equal 1, Concierge::SlackCard.posted_today(:billing).count
    end

    test "a Slack outage records the failure and never fails the proposal" do
      @transport.fail_with = Concierge::Slack::ApiError.new("channel_not_found")

      row = propose(@billing)

      assert row.persisted?, "a broken Slack cost us the proposal"
      assert row.proposed?
      card = Concierge::SlackCard.sole
      assert card.failed?
      assert_match "channel_not_found", card.error
    end

    test "a proposal is carded exactly once even if the notifier runs again" do
      row = propose(@billing)

      Concierge::Slack::Notifier.call(row)

      assert_equal 1, Concierge::SlackCard.where(agent_proposal_id: row.id).count
      assert_equal 1, @transport.calls_to("chat.postMessage").size
    end

    test "no card is posted when Slack is not configured at all" do
      Concierge.reset_config!
      Concierge::Test.configure!
      Concierge::Test.configure_agents!

      row = propose(@billing)

      assert row.proposed?
      assert_equal 0, Concierge::SlackCard.count
    end

    test "an autonomous action is never carded, because it never proposes" do
      # The CSM is :autonomous on messages: there is nothing to stage, so there is
      # nothing to interrupt anyone about. Digests cover that work instead.
      assert_raises Concierge::Proposal::GateError do
        Concierge::Proposal.propose(csm_scope, action_class: "message.outreach",
                                              payload: { body: "hi" })
      end
      assert_equal 0, Concierge::SlackCard.count
    end

    private

    def propose(scope, key: nil, action_class: "record.plan_change")
      Concierge::Proposal.propose(scope, action_class: action_class,
                                         payload: { "from" => "pro", "to" => "enterprise" },
                                         idempotency_key: key || "key-#{SecureRandom.hex(4)}")
    end

    def csm_scope
      Concierge::Scope.new(Concierge.config.agent(:csm), @acme)
    end

    def subject_for(name)
      tenant = Tenant.create!(name: name, plan: "pro")
      tenant.users.create!(email: "user@#{name.downcase}.test")
      Concierge.config.account.build(tenant)
    end
  end
end
