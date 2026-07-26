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

    # The documented offline path, end to end: no credentials anywhere, and the
    # host has swapped in a scripted chat. This is the exact call from the bug
    # report, which raised RubyLLM::ConfigurationError before the fix.
    test "a proactive run answers with no provider credentials at all" do
      Concierge::Test::FakeChat.script(reply: "Offline, but still here.")

      result = nil
      without_provider_credentials do
        assert_nothing_raised { result = Concierge::Run.proactive(@subject, instruction: "hi") }
      end

      assert result.ok?
      assert_equal "Offline, but still here.", result.reply_text
    end

    # ...and it degrades rather than pretending. A host with no credentials that
    # never supplied an offline chat_factory gets the default one, which does try
    # to reach the provider — that must come back failed, not raised and not
    # quietly green. RubyLLM derives ConfigurationError from StandardError rather
    # than RubyLLM::Error, so it used to sail through Run's rescue untouched.
    test "no credentials and no offline chat is a failed Result, not a raise" do
      Concierge.config.chat_factory = Concierge::Configuration::DEFAULT_CHAT_FACTORY

      result = nil
      without_provider_credentials do
        assert_nothing_raised { result = Concierge::Run.reactive(@subject, "hi") }
      end

      refute result.ok?, "an unreachable provider reported a successful run"
      assert_kind_of RubyLLM::ConfigurationError, result.error
    end

    # Provenance is how an operator finds out. A run that could not reach the
    # model is recorded as failed with its error class, not left unaccounted for.
    test "a run with no credentials records failed provenance" do
      Concierge.config.chat_factory = Concierge::Configuration::DEFAULT_CHAT_FACTORY

      without_provider_credentials { Concierge::Run.reactive(@subject, "hi") }

      run = Concierge::AgentRun.order(:id).last

      assert_equal "failed", run.status
      assert_equal "RubyLLM::ConfigurationError", run.error_class

      # The conversation was opened before the turn was attempted, and survives
      # the failure — a host that later sets its key continues this thread rather
      # than starting a new one. Only the *turn* failed.
      assert_equal Concierge::Conversation.find_by_scope(Concierge::Scope.coerce(@subject)).chat_id,
                   run.chat_id
      assert_nil run.message_id, "a failed turn recorded a reply it never got"
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
