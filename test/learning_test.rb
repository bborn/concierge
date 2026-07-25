require "test_helper"

module Concierge
  class LearningTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "capture writes a human-sourced, pinned memory" do
      Learning.capture(@subject, content: "This account hates automated emails.")

      memory = Memory.for_subject(@subject).first
      assert_equal "human", memory.source
      assert memory.pinned
    end

    test "blank content is ignored" do
      assert_nil Learning.capture(@subject, content: "   ")
      assert_equal 0, Memory.for_subject(@subject).count
    end

    test "captured human memory appears ahead of agent memory in the next run's prompt" do
      ContextStore.new.remember(@subject, body: "agent-guessed preference", source: :agent)
      Learning.capture(@subject, content: "operator: they prefer a phone call")

      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@subject, "hi")
      prompt = Concierge::Test::FakeChat.current.system_prompt

      human_pos = prompt.index("they prefer a phone call")
      agent_pos = prompt.index("agent-guessed preference")
      assert human_pos && agent_pos
      assert human_pos < agent_pos, "human-sourced memory should lead"
    end

    test "draft_and_review routes outreach to the outbox instead of sending" do
      Concierge.config.draft_and_review = true
      status = Outreach.deliver(Concierge::Result.new(reply_text: "a proactive nudge"), @subject, channel: :in_app)

      assert_equal :drafted, status
      assert_equal 1, AgentProposal.for_subject(@subject).proposed.count
      assert_equal 0, ChannelDelivery.count
    end

    test "default (autonomous) still delivers" do
      status = Outreach.deliver(Concierge::Result.new(reply_text: "a proactive nudge"), @subject, channel: :in_app)
      assert_equal :delivered, status
    end

    test "the legacy draft_and_review flag still tightens a pluralized host" do
      # §10.5 makes the flag sugar for ":human_approval on the CSM's message
      # class". A host that flips it on and *also* declares agents must not
      # silently get autonomous sends back — the flag may only tighten.
      Concierge::Test.configure_agents!
      Concierge.config.draft_and_review = true
      scope = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)

      assert_equal :autonomous, Concierge.config.agent(:csm).authority.level_for("message.outreach")
      assert_equal :drafted,
                   Outreach.deliver(Concierge::Result.new(reply_text: "a nudge"), scope, channel: :in_app)
      assert_equal 1, AgentProposal.for_scope(scope).proposed.count
    end
  end
end
