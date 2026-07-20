require "test_helper"

module Concierge
  class RunTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "reactive returns a Result with the scripted reply" do
      Concierge::Test::FakeChat.script(reply: "Hi there!")

      result = Concierge::Run.reactive(@subject, "hello")

      assert result.ok?
      assert_equal "Hi there!", result.reply_text
      assert_equal 15, result.total_tokens
    end

    test "the assembled prompt carries brief, snapshot, and memory" do
      Concierge::ContextStore.new.remember(@subject, body: "prefers Slack over email")
      Concierge::Test::FakeChat.script(reply: "ok")

      Concierge::Run.reactive(@subject, "hi")
      prompt = Concierge::Test::FakeChat.current.system_prompt

      assert_includes prompt, "Acme helps teams publish changelogs."   # product brief
      assert_includes prompt, "Account state:"                          # snapshot
      assert_includes prompt, "has_paid_plan: yes"
      assert_includes prompt, "prefers Slack over email"               # top-of-mind memory
      assert_includes prompt, "Kit"                                     # persona
    end

    test "a mid-stream RubyLLM error becomes a failed Result, never raised" do
      Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))

      result = nil
      assert_nothing_raised { result = Concierge::Run.reactive(@subject, "hi") }
      refute result.ok?
      assert_kind_of RubyLLM::Error, result.error
    end

    test "a tool call during the run mutates only this subject's data" do
      other = Tenant.create!(name: "Beta", plan: "free")
      Concierge::Test::FakeChat.script(
        reply: "Noted.",
        tool_calls: [ { name: "remember", arguments: { body: "wants a weekly report" } } ]
      )

      Concierge::Run.reactive(@subject, "please send me a weekly report")

      assert_equal 1, Memory.for_subject(@subject).count
      assert_equal "wants a weekly report", Memory.for_subject(@subject).first.body
      assert_equal 0, Memory.for_subject(Concierge.config.account.build(other)).count
    end

    test "two subjects resolve two distinct persistent chats" do
      other = Tenant.create!(name: "Beta", plan: "free")
      other_subject = Concierge.config.account.build(other)

      Concierge::Test::FakeChat.script(reply: "a")
      Concierge::Run.reactive(@subject, "hi")
      Concierge::Test::FakeChat.script(reply: "b")
      Concierge::Run.reactive(other_subject, "hi")

      chat_a = Conversation.find_by_subject(@subject).chat_id
      chat_b = Conversation.find_by_subject(other_subject).chat_id
      refute_equal chat_a, chat_b
    end

    test "a subject reuses its persistent chat across runs" do
      Concierge::Test::FakeChat.script(reply: "one")
      Concierge::Run.reactive(@subject, "first")
      Concierge::Test::FakeChat.script(reply: "two")
      Concierge::Run.reactive(@subject, "second")

      assert_equal 1, Conversation.where(subject_id: @subject.id.to_s).count
    end
  end
end
