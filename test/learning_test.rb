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
      assert_equal 1, OutboxItem.for_subject(@subject).pending.count
      assert_equal 0, ChannelDelivery.count
    end

    test "default (autonomous) still delivers" do
      status = Outreach.deliver(Concierge::Result.new(reply_text: "a proactive nudge"), @subject, channel: :in_app)
      assert_equal :delivered, status
    end
  end
end
