require "test_helper"

module Concierge
  # The run row records what the agent was told (pins) and what it says it did
  # (the citation) — and, until this, nothing about what it actually said. Those
  # two are indistinguishable between a turn that followed an advisory rule and
  # one that contradicted it while sincerely citing it (design §10.4, turns B and
  # C). Reading the reply is the check the engine cannot perform, so the row has
  # to be able to point at it.
  #
  # Every test here that asserts the link *exists* runs the real path: real
  # RubyLLM::Chat, real +acts_as_chat+ persistence callbacks, real provider
  # response parsing, with only the HTTP hop stubbed. Asserting message
  # persistence against a double that fakes the persistence would prove nothing —
  # that is exactly the shape of masking that hid a broken online path for a whole
  # phase.
  class RunReplyLinkTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    end

    # --- the real path -------------------------------------------------------

    test "a run points at the assistant message the host persisted for its turn" do
      persisting_host!
      rule = activate(@csm, "Keep the tone low-key and never mention automation.")

      result = with_model_reply(
        "Yes — I'm an AI assistant helping out with support.\n\nRules-Applied: #{rule.id}"
      ) { Concierge::Run.reactive(@csm, "am I talking to a bot?") }

      assert result.ok?, "the run failed: #{result.error&.message}"
      run = result.run_record

      assert run.message_id, "the run recorded no reply message"
      assert_equal run.chat_id, run.reply_message.chat_id
      assert_nil run.reply_unavailable_reason
    end

    # Turn C, end to end: pins, citation and reply on one row. The first two say
    # the rule was applied. Only the third shows it was contradicted.
    test "the reply is what separates a cited-and-followed turn from a cited-and-contradicted one" do
      persisting_host!
      rule = activate(@csm, "Keep the tone low-key and never mention automation.")

      contradicted = with_model_reply(
        "Yes — I'm an AI assistant helping out with support.\n\nRules-Applied: #{rule.id}"
      ) { Concierge::Run.reactive(@csm, "am I talking to a bot?") }.run_record

      complied = with_model_reply(
        "Happy to help with that.\n\nRules-Applied: #{rule.id}"
      ) { Concierge::Run.reactive(@csm, "can you help?") }.run_record

      # Indistinguishable on everything the engine writes...
      assert_equal complied.rules, contradicted.rules
      assert_equal complied.rule_ids_applied, contradicted.rule_ids_applied
      assert_equal complied.unknown_rule_ids, contradicted.unknown_rule_ids

      # ...and told apart only by the words.
      assert_includes contradicted.reply_text, "I'm an AI assistant"
      refute_includes complied.reply_text, "I'm an AI assistant"
    end

    # The watermark. Two turns on one thread must not both resolve to the newest
    # reply, and a turn that persisted nothing must not inherit the previous
    # turn's words — an operator would spot-check the wrong reply believing it was
    # this one.
    test "each turn points at its own reply, not the newest one on the thread" do
      persisting_host!

      first  = with_model_reply("First answer.")  { Concierge::Run.reactive(@csm, "one") }.run_record
      second = with_model_reply("Second answer.") { Concierge::Run.reactive(@csm, "two") }.run_record

      refute_equal first.message_id, second.message_id
      assert_equal "First answer.",  first.reply_text
      assert_equal "Second answer.", second.reply_text
    end

    test "a turn that persisted nothing does not inherit the previous turn's reply" do
      persisting_host!
      persisted = with_model_reply("The words that were written down.") do
        Concierge::Run.reactive(@csm, "one")
      end.run_record

      # The host stops persisting mid-thread — a scripted double, a swapped
      # factory, a chat model that keeps no messages.
      Concierge::Test::FakeChat.script(reply: "Never written down.")
      Concierge.config.chat_factory = ->(model:, chat_record: nil) { Concierge::Test::FakeChat.current }
      orphan = Concierge::Run.reactive(@csm, "two").run_record

      assert_nil orphan.message_id
      assert_nil orphan.reply_text
      assert_equal :not_persisted, orphan.reply_unavailable_reason
      assert_equal "The words that were written down.", persisted.reply_text
    end

    # --- degrading -----------------------------------------------------------

    test "a host that persists no messages says so rather than showing nothing" do
      Concierge::Test::FakeChat.script(reply: "Hello!")
      run = Concierge::Run.reactive(@csm, "hi").run_record

      assert run.chat_id, "the credentialed path recorded no chat"
      assert_nil run.message_id
      assert_equal :not_persisted, run.reply_unavailable_reason
    end

    # An uncredentialed run *does* have a host chat now (task 5017) — the engine
    # resolves the model record itself, so opening the conversation never needs a
    # provider. What it may still lack is a message in it, because that is the
    # host's factory's job and this one is a double that keeps nothing. The screen
    # has to say which of the two it is: "no conversation was ever opened" and
    # "the conversation exists and this turn left nothing in it" send an operator
    # to different places.
    test "an uncredentialed run has a host chat, and says when nothing was written in it" do
      without_provider_credentials do
        Concierge::Test::FakeChat.script(reply: "Offline reply.")
        run = Concierge::Run.reactive(@csm, "hi").run_record

        assert run.chat_id, "a keyless run recorded no host chat"
        assert_nil run.message_id
        assert_equal :not_persisted, run.reply_unavailable_reason
      end
    end

    test "a pruned message leaves a visible gap, not a silent one" do
      persisting_host!
      run = with_model_reply("Read me while you can.") do
        Concierge::Run.reactive(@csm, "hi")
      end.run_record

      run.reply_message.destroy!

      assert_nil run.reload.reply_text
      assert_equal :pruned, run.reply_unavailable_reason
      assert run.message_id, "the pointer was dropped along with the message"
    end

    test "a pruned chat leaves a visible gap too" do
      persisting_host!
      run = with_model_reply("Read me while you can.") do
        Concierge::Run.reactive(@csm, "hi")
      end.run_record

      Chat.find(run.chat_id).destroy!

      assert_nil run.reload.reply_message
      assert_equal :pruned, run.reply_unavailable_reason
    end

    test "a failed run links to no reply" do
      persisting_host!
      Concierge.config.chat_factory = lambda do |model:, chat_record: nil|
        Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))
        Concierge::Test::FakeChat.current
      end

      result = Concierge::Run.reactive(@csm, "hi")

      refute result.ok?
      run = Concierge::AgentRun.for_scope(@csm).recent.first
      assert_equal "failed", run.status
      assert_nil run.message_id
    end

    # --- what is stored, and what is not -------------------------------------

    # §10.12: the reply is customer-facing text under the host's retention
    # policy. Concierge prunes provenance on its own cadence, so copying the words
    # onto the run row would be the engine deciding a privacy question that
    # belongs to the host.
    test "the run row stores a pointer, never the words" do
      persisting_host!
      run = with_model_reply("Something a customer said something back to.") do
        Concierge::Run.reactive(@csm, "hi")
      end.run_record

      stored = run.attributes.values.map(&:to_s).join(" ")

      refute_includes stored, "Something a customer said something back to."
      assert_includes run.reply_text, "Something a customer said something back to."
    end

    # The engine strips the citation line out of the reply it hands a channel, so
    # it never reaches a customer. The host's own record of the turn is the raw
    # model output — which is what an auditor needs to see.
    test "the linked message is the raw reply, citation line and all" do
      persisting_host!
      rule = activate(@csm, "Never promise a delivery date.")

      result = with_model_reply("No date yet.\n\nRules-Applied: #{rule.id}") do
        Concierge::Run.reactive(@csm, "when does it ship?")
      end

      refute_includes result.reply_text, "Rules-Applied"
      assert_includes result.run_record.reply_text, "Rules-Applied: #{rule.id}"
    end

    private

    # Take FakeChat out of the loop: resume the persisted conversation through
    # acts_as_chat, exactly as an online host does.
    def persisting_host!
      Concierge.config.chat_factory = persisting_chat_factory
    end

    def activate(scope, body)
      rule = Concierge::Rules.propose(scope, body: body, author: "drafter")
      Concierge::Rules.activate!(rule, by: "sam@acme.test")
      rule
    end
  end
end
