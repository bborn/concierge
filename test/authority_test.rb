require "test_helper"

module Concierge
  # The per-agent authority envelope (design §10.5), and the one place it does
  # work today: whether an agent may send outreach on its own, or must stage it
  # for a human. §10.6 generalizes the staged row into an AgentProposal over
  # arbitrary action classes — this is the mechanism that step builds on.
  class AuthorityTest < ActiveSupport::TestCase
    setup do
      @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "an action class falls back to the agent's default" do
      envelope = Concierge::Authority.new
      envelope.default :human_approval

      assert_equal :human_approval, envelope.level_for("anything.at.all")
      assert_equal :human_approval, envelope.level_for(Authority::MESSAGE_OUTREACH)
    end

    test "a declared action class overrides the default in either direction" do
      envelope = Concierge::Authority.new
      envelope.default :human_approval
      envelope.action "money.refund", :human_execution
      envelope.action Authority::MESSAGE_OUTREACH, :autonomous

      assert_equal :human_execution, envelope.level_for("money.refund")
      assert_equal :autonomous,      envelope.level_for(Authority::MESSAGE_OUTREACH)
      assert envelope.human_execution?("money.refund")
      refute envelope.autonomous?("money.refund")
    end

    test "an unknown level raises at configure time, not at run time" do
      assert_raises(Concierge::Error) { Concierge::Authority.new.default :yolo }
      assert_raises(Concierge::Error) { Concierge::Authority.new.action "x", :sudo }
    end

    test ":autonomous sends; anything else stages the send for a human" do
      %i[autonomous human_approval human_execution].each do |level|
        Concierge.reset_config!
        Concierge::Test.configure!
        Concierge.configure { |c| c.agent(:ops) { authority { default level } } }

        # A fresh account per level: an autonomous send records a delivery, and
        # the frequency cap is per customer across agents (see Governance).
        tenant = Tenant.create!(name: "Acme #{level}", plan: "pro")
        tenant.users.create!(email: "#{level}@acme.test")
        scope = Concierge::Scope.new(Concierge.config.agent(:ops),
                                     Concierge.config.account.build(tenant))

        status = Concierge::Outreach.deliver(
          Concierge::Result.new(reply_text: "a nudge"), scope, channel: :in_app
        )

        if level == :autonomous
          assert_equal :delivered, status, "#{level} should have sent"
          assert_equal 0, Concierge::OutboxItem.for_scope(scope).count
        else
          assert_equal :drafted, status, "#{level} should have staged for a human"
          assert_equal 1, Concierge::OutboxItem.for_scope(scope).pending.count
        end
      end
    end

    test "a staged proposal is attributed to the agent that proposed it" do
      Concierge::Test.configure_agents!
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

      Concierge::Outreach.deliver(
        Concierge::Result.new(reply_text: "your card expires soon"), billing, channel: :email
      )

      row = Concierge::OutboxItem.sole
      assert_equal "billing", row.agent_slug
      assert_equal "your card expires soon", row.body
      assert_equal 0, Concierge::ChannelDelivery.count, "a staged proposal must not also send"
    end

    test "a gated agent's send is staged even when governance would allow it" do
      # The envelope is asked *before* the channel is picked, so the gate cannot
      # be bypassed by a host with no channels configured, or a preferred one.
      Concierge::Test.configure_agents!
      Concierge.config.channels = []
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

      assert_equal :drafted, Concierge::Outreach.deliver(
        Concierge::Result.new(reply_text: "invoice question"), billing
      )
    end

    test "the CSM stays autonomous-within-caps — the standing guidance is unchanged" do
      Concierge::Test.configure_agents!
      csm = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)

      assert_equal :delivered, Concierge::Outreach.deliver(
        Concierge::Result.new(reply_text: "a nudge"), csm, channel: :in_app
      )
    end
  end
end
