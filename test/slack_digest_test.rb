require "test_helper"

module Concierge
  # Anti-noise, the other half (§2.6): work an agent did on its own authority
  # arrives as one periodic digest, not a card each. A channel that cries wolf is a
  # channel where the refund card gets scrolled past.
  class SlackDigestTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @transport = Concierge::Test.configure_slack!
      @acme   = subject_for("Acme")
      @globex = subject_for("Globex")
      @csm    = Concierge::Scope.new(Concierge.config.agent(:csm), @acme)
    end

    test "autonomous sends are summarised in one message, per account" do
      3.times { Concierge::Governance.new.record!(@csm, channel: "email") }
      Concierge::Governance.new.record!(Concierge::Scope.new(Concierge.config.agent(:csm), @globex),
                                        channel: "in_app")

      Concierge::Slack::Digest.deliver(:csm)

      calls = @transport.calls_to("chat.postMessage")
      assert_equal 1, calls.size, "a digest posted more than one message"
      assert_equal "C0CSM", calls.first.payload[:channel]
      rendered = @transport.rendered("chat.postMessage")
      assert_match "account ##{@acme.id}", rendered
      assert_match "3× email", rendered
      assert_match "account ##{@globex.id}", rendered
    end

    test "a digest never pings a channel" do
      Concierge::Governance.new.record!(@csm, channel: "email")

      Concierge::Slack::Digest.deliver(:csm)

      rendered = @transport.rendered("chat.postMessage")
      refute_match "<!channel>", rendered
      refute_match "<!here>", rendered
    end

    test "nothing to report posts nothing at all" do
      Concierge::Slack::Digest.deliver(:csm)

      assert_empty @transport.calls_to("chat.postMessage")
    end

    test "a digest never reports another agent's work" do
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @acme)
      Concierge::Governance.new.record!(billing, channel: "email")

      Concierge::Slack::Digest.deliver(:csm)

      assert_empty @transport.calls_to("chat.postMessage"),
                   "the CSM's digest reported billing's work"
    end

    test "work a human approved is not reported as unilateral" do
      # It already had a card. Reporting it again as something the agent did on its
      # own authority would be a lie about who decided it.
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @acme)
      row = Concierge::Proposal.propose(billing, action_class: "message.outreach",
                                                 payload: { "body" => "your card expires soon" },
                                                 idempotency_key: "msg-1")
      Concierge::ApprovalIntake.approve(row, by: "sam@acme.test")
      assert row.reload.executed?, "the fixture did not actually deliver"

      # The card the proposal itself posted is already in the transport, so count
      # from there: the digest must add nothing.
      before = @transport.calls_to("chat.postMessage").size
      Concierge::Slack::Digest.deliver(:billing)

      assert_equal before, @transport.calls_to("chat.postMessage").size,
                   "an action a human approved was reported as unilateral work"
    end

    test "a digest says what is still waiting on a human" do
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @acme)
      Concierge::Proposal.propose(billing, action_class: "record.plan_change",
                                           payload: { "to" => "enterprise" },
                                           idempotency_key: "plan-1")

      Concierge::Slack::Digest.deliver(:billing)

      assert_match "still waiting on a human", @transport.rendered("chat.postMessage")
    end

    test "a digest owns up to the cards the cap suppressed" do
      @transport = Concierge::Test.configure_slack!(cap: 0)
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @acme)
      Concierge::Proposal.propose(billing, action_class: "record.plan_change",
                                           payload: { "to" => "enterprise" },
                                           idempotency_key: "plan-2")

      Concierge::Slack::Digest.deliver(:billing)

      rendered = @transport.rendered("chat.postMessage")
      assert_match "1 card was not posted here", rendered
      assert_match "they are in the queue", rendered
    end

    test "deliver_all posts one digest per agent that has a channel" do
      Concierge::Governance.new.record!(@csm, channel: "email")
      Concierge::Governance.new.record!(Concierge::Scope.new(Concierge.config.agent(:billing), @acme),
                                        channel: "email")

      Concierge::Slack::Digest.deliver_all

      assert_equal %w[C0CSM C0BILLING].sort,
                   @transport.calls_to("chat.postMessage").map { |c| c.payload[:channel] }.sort
    end

    test "the job is what a host schedules, and it is not the sweep" do
      # A digest on the sweep's cadence would be the noise it exists to prevent.
      Concierge::Governance.new.record!(@csm, channel: "email")

      Concierge::SlackDigestJob.perform_now

      assert_equal 1, @transport.calls_to("chat.postMessage").size
    end

    test "a broken Slack does not fail the digest's caller" do
      Concierge::Governance.new.record!(@csm, channel: "email")
      @transport.fail_with = Concierge::Slack::ApiError.new("channel_not_found")

      assert_nil Concierge::Slack::Digest.deliver(:csm)
    end

    private

    def subject_for(name)
      tenant = Tenant.create!(name: name, plan: "pro")
      tenant.users.create!(email: "user@#{name.downcase}.test")
      Concierge.config.account.build(tenant)
    end
  end
end
