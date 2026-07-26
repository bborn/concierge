require "test_helper"

module Concierge
  # The persistent-Chat feature, actually tested.
  #
  # `Run` drives whatever `config.chat_factory` returns, and the default returned
  # `chat_record.to_llm` — a RubyLLM::Chat. In ruby_llm 1.16 that object's
  # persistence callbacks write the *assistant* message and nothing else; the user
  # turn is written by `ChatMethods#ask` on the AR record, which nobody was
  # calling. So after a turn the host's messages table held exactly one row, the
  # reply, and the customer's question was nowhere.
  #
  # That was invisible to the suite because FakeChat replaces the whole chat
  # object, so no test ever reached `acts_as_chat` at all — the same shape of
  # masking that hid a broken online path for a whole phase (task #14). Every test
  # here therefore runs the real thing: real RubyLLM::Chat, real acts_as_chat
  # callbacks, real Anthropic response parsing, with only the HTTP POST stubbed.
  # Several assert on the request payload rather than the reply, because a dropped
  # row is invisible in a reply and shows up only in what the model is next shown.
  class OnlineTranscriptTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
      @subject = Concierge.config.account.build(@tenant)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
      Concierge.config.chat_factory = persisting_chat_factory
    end

    # --- the defect ----------------------------------------------------------

    test "the customer's question is persisted alongside the agent's reply" do
      with_model_reply("Publishing takes about a minute.") do
        Concierge::Run.reactive(@csm, "how do I publish a changelog?")
      end

      assert_equal [ [ "user", "how do I publish a changelog?" ],
                     [ "assistant", "Publishing takes about a minute." ] ],
                   transcript
    end

    # The consequence that matters. `to_llm` rebuilds the in-memory thread from
    # the persisted rows, so a dropped question is not merely a gap in an audit
    # log: it is a conversation history that reads to the model as its own
    # monologue.
    test "the second turn shows the model a dialogue, not its own monologue" do
      with_model_reply("First answer.")  { Concierge::Run.reactive(@csm, "first question") }
      with_model_reply("Second answer.") { Concierge::Run.reactive(@csm, "second question") }

      assert_equal [ %w[user first\ question], [ "assistant", "First answer." ],
                     %w[user second\ question] ],
                   last_request_messages.map { |m| [ m[:role], m[:text] ] }
    end

    # Not a nicety: the Anthropic Messages API requires the first message to be a
    # user turn. A thread opened proactively persisted only the agent's outreach,
    # so the *next* turn on it put an assistant message first on the wire — a 400
    # from a live provider, on a path no test could see.
    test "a thread opened proactively still starts with a user turn on the next one" do
      with_model_reply("Noticed you haven't published yet — want a hand?") do
        Concierge::Run.proactive(@csm, instruction: "Nudge them about publishing.")
      end
      with_model_reply("Sure — open Changelog, then New entry.") do
        Concierge::Run.reactive(@csm, "yes please")
      end

      assert_equal "user", last_request_messages.first[:role],
                   "the provider was sent a conversation beginning with an assistant turn"
    end

    # --- what must NOT be persisted ------------------------------------------

    # The reason the obvious fix (hand Run the AR record, same fluent surface) is
    # wrong: `ChatMethods#with_instructions` persists the system prompt as a
    # message row. Concierge assembles that prompt fresh every run out of the
    # account's memories, the rules in force and a live snapshot, so persisting it
    # would copy the account's memory into the host's customer-facing store on
    # every turn — the host's retention decision to make, not the engine's
    # (§10.12) — and leave a stale copy for `to_llm` to replay next to the fresh
    # one on the following turn.
    test "the assembled system prompt never reaches the host's message store" do
      Concierge::ContextStore.new.remember(@csm, body: "Dana's team is migrating from Notion.")
      rule = activate(@csm, "Never promise a delivery date.")

      with_model_reply("No date yet.") { Concierge::Run.reactive(@csm, "when does it ship?") }

      assert_empty Message.where(role: "system"), "the system prompt was written to the host"
      stored = Message.pluck(:content).join(" ")
      refute_includes stored, "Dana's team is migrating from Notion."
      refute_includes stored, "Never promise a delivery date."
      refute_includes stored, "rule #{rule.id}"
    end

    test "a stale system prompt is never replayed alongside the fresh one" do
      with_model_reply("First answer.")  { Concierge::Run.reactive(@csm, "one") }
      with_model_reply("Second answer.") { Concierge::Run.reactive(@csm, "two") }

      assert_empty last_request_messages.select { |m| m[:role] == "system" },
                   "a system prompt was replayed as a conversation message"
    end

    # --- failure and degradation ---------------------------------------------

    # A turn that never reached the model did not happen, and the thread should
    # look as it did before it. Leaving the question behind would make the retry
    # send it twice; RubyLLM's own AR path cleans up after itself the same way.
    test "a failed turn leaves the thread exactly as it was" do
      with_model_reply("First answer.") { Concierge::Run.reactive(@csm, "one") }
      before = transcript

      result = with_model_error { Concierge::Run.reactive(@csm, "two") }

      refute result.ok?, "the turn was supposed to fail"
      assert_equal before, transcript
    end

    test "a host whose factory persists nothing is unchanged" do
      Concierge::Test::FakeChat.script(reply: "Hello!")
      Concierge.config.chat_factory = ->(model:, chat_record: nil) { Concierge::Test::FakeChat.current }

      run = Concierge::Run.reactive(@csm, "hi").run_record

      assert_empty Message.all
      assert_nil run.prompt_message_id
      assert_equal :not_persisted, run.prompt_unavailable_reason
    end

    # The engine's one promise is that a bad turn never crashes the host. A host
    # message store that refuses the write degrades the transcript; it must not
    # swallow an answer the customer is waiting on.
    test "a message store that refuses the write does not fail the turn" do
      Concierge.config.chat_factory = lambda do |model:, chat_record: nil|
        # Scoped to this one record, so nothing leaks into the rest of the suite.
        chat_record.define_singleton_method(:add_message) do |*|
          raise ActiveRecord::RecordNotSaved, "no room at the inn"
        end
        Concierge::PersistentChat.new(chat_record.to_llm, chat_record)
      end

      result = with_model_reply("Answered anyway.") { Concierge::Run.reactive(@csm, "hi") }

      assert result.ok?, "a host storage failure took the reply down with it"
      assert_equal "Answered anyway.", result.reply_text
      assert_nil result.run_record.prompt_message_id
      assert_equal "Answered anyway.", result.run_record.reply_text
    end

    # --- the run row ---------------------------------------------------------

    test "a run points at the question it answered as well as the answer" do
      run = with_model_reply("Publishing takes about a minute.") do
        Concierge::Run.reactive(@csm, "how do I publish?")
      end.run_record

      assert_equal "how do I publish?", run.prompt_text
      assert_equal "Publishing takes about a minute.", run.reply_text
      assert_equal run.chat_id, run.prompt_message.chat_id
      assert_nil run.prompt_unavailable_reason
    end

    # The watermark, on the question side. Two turns on one thread must not both
    # resolve to the newest one.
    test "each turn points at its own question, not the newest on the thread" do
      first  = with_model_reply("First answer.")  { Concierge::Run.reactive(@csm, "one") }.run_record
      second = with_model_reply("Second answer.") { Concierge::Run.reactive(@csm, "two") }.run_record

      refute_equal first.prompt_message_id, second.prompt_message_id
      assert_equal "one", first.prompt_text
      assert_equal "two", second.prompt_text
    end

    # ...and the case the watermark actually exists for. A turn that persisted
    # nothing must link to nothing: inheriting the previous turn's question would
    # put an operator in front of the wrong words believing they were this run's,
    # which is worse than showing them none.
    test "a turn that persisted nothing does not inherit the previous turn's question" do
      persisted = with_model_reply("The words that were written down.") do
        Concierge::Run.reactive(@csm, "one")
      end.run_record

      Concierge::Test::FakeChat.script(reply: "Never written down.")
      Concierge.config.chat_factory = ->(model:, chat_record: nil) { Concierge::Test::FakeChat.current }
      orphan = Concierge::Run.reactive(@csm, "two").run_record

      assert_nil orphan.prompt_message_id
      assert_nil orphan.prompt_text
      assert_equal :not_persisted, orphan.prompt_unavailable_reason
      assert_equal "one", persisted.prompt_text
    end

    # §10.12, on the question side too: these are the customer's own words, so the
    # provenance row keeps a pointer and the host keeps the text.
    test "the run row stores a pointer to the question, never the words" do
      run = with_model_reply("Sure.") do
        Concierge::Run.reactive(@csm, "something a customer typed")
      end.run_record

      stored = run.attributes.values.map(&:to_s).join(" ")

      refute_includes stored, "something a customer typed"
      assert_includes run.prompt_text, "something a customer typed"
    end

    test "a pruned question leaves a visible gap, not a silent one" do
      run = with_model_reply("Sure.") { Concierge::Run.reactive(@csm, "read me while you can") }.run_record

      run.prompt_message.destroy!

      assert_nil run.reload.prompt_text
      assert_equal :pruned, run.prompt_unavailable_reason
      assert run.prompt_message_id, "the pointer was dropped along with the message"
    end

    private

    def transcript
      Message.order(:id).map { |m| [ m.role.to_s, m.content.to_s ] }
    end

    def activate(scope, body)
      rule = Concierge::Rules.propose(scope, body: body, author: "drafter")
      Concierge::Rules.activate!(rule, by: "sam@acme.test")
      rule
    end
  end
end
