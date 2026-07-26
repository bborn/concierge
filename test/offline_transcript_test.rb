require "test_helper"

module Concierge
  # The other half of OnlineTranscriptTest: what a host with **no provider
  # credentials** ends up with.
  #
  # It used to be nothing. `ChatResolver` declined to create the host Chat at all
  # without credentials — creating one made `acts_as_chat` resolve a model, and
  # resolving instantiated the provider — so a keyless host had no `Conversation`,
  # no chat rows, and no messages. Every surface that reads the host's chat tables
  # was therefore permanently empty offline: the widget's tool-call strip, and both
  # halves of the run screen. A change to what the engine persists could not be
  # demonstrated by driving the running demo at all, only by reading seeded
  # stand-ins — which is the same displacement of coverage that let an entirely
  # broken online path look fine for a phase (task #14), moved from the suite to
  # the demo.
  #
  # These tests run the real host models with credentials genuinely removed, and
  # the demo host's own scripted factory rather than a double written for them, so
  # what they cover is the code the offline server runs.
  class OfflineTranscriptTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
      @subject = Concierge.config.account.build(@tenant)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
      Concierge.config.chat_factory = ->(model:, chat_record: nil) { Dummy::ScriptedChat.new(chat_record) }
    end

    # --- the defect ----------------------------------------------------------

    test "a keyless turn leaves a conversation behind" do
      without_provider_credentials { Concierge::Run.reactive(@csm, "how do I publish?") }

      conversation = Concierge::Conversation.find_by_scope(@csm)

      assert conversation, "a keyless host recorded no conversation for this scope"
      assert Concierge.chat_model.find_by(id: conversation.chat_id), "the conversation points at no chat"
    end

    test "both halves of a keyless turn are written down" do
      without_provider_credentials { Concierge::Run.reactive(@csm, "how do I publish?") }

      roles, contents = transcript.transpose

      assert_equal %w[user assistant], roles
      assert_equal "how do I publish?", contents.first
      assert_includes contents.last, "Changelog"
    end

    # The screens this whole task is about. Before, every offline run read
    # :no_host_chat on both — the honest answer to "there is no conversation",
    # and a permanently dead screen in the demo.
    test "a keyless run's provenance links to the question and the reply" do
      run = without_provider_credentials do
        Concierge::Run.reactive(@csm, "how do I publish?")
      end.run_record

      assert_nil run.prompt_unavailable_reason
      assert_nil run.reply_unavailable_reason
      assert_equal "how do I publish?", run.prompt_text
      assert_equal run.chat_id, run.reply_message.chat_id
    end

    # The thread is a thread: the second keyless turn continues the first rather
    # than opening a new conversation beside it.
    test "a second keyless turn continues the same thread" do
      without_provider_credentials do
        Concierge::Run.reactive(@csm, "how do I publish?")
        Concierge::Run.reactive(@csm, "what about billing?")
      end

      assert_equal 1, Concierge::Conversation.for_scope(@csm).count
      assert_equal %w[user assistant user assistant], transcript.map(&:first)
    end

    # ...and each run points at its own turn, not the newest on the thread — the
    # watermark holds offline exactly as it does online.
    test "each keyless run points at its own question" do
      first, second = without_provider_credentials do
        [ Concierge::Run.reactive(@csm, "one").run_record,
          Concierge::Run.reactive(@csm, "two").run_record ]
      end

      assert_equal "one", first.prompt_text
      assert_equal "two", second.prompt_text
      refute_equal first.message_id, second.message_id
    end

    # --- what has not changed -------------------------------------------------

    # Persisting the conversation is not pretending the model is there. A keyless
    # host that supplied no offline factory still fails its turns, loudly, with
    # the provider's own error — it simply has a conversation to have failed on.
    test "a keyless host with no offline factory still fails its turns" do
      Concierge.config.chat_factory = Concierge::Configuration::DEFAULT_CHAT_FACTORY

      result = without_provider_credentials { Concierge::Run.reactive(@csm, "hi") }

      refute result.ok?, "a run with no provider and no offline factory reported success"
      assert_kind_of RubyLLM::ConfigurationError, result.error
      assert_empty Message.all, "a failed turn wrote a transcript"
    end

    test "the assembled system prompt never reaches the host's message store offline either" do
      Concierge::ContextStore.new.remember(@csm, body: "Dana's team is migrating from Notion.")

      without_provider_credentials { Concierge::Run.reactive(@csm, "hi") }

      assert_empty Message.where(role: "system")
      refute_includes Message.pluck(:content).join(" "), "Dana's team is migrating from Notion."
    end

    # The engine's one promise, on the offline path too: a host message store that
    # refuses the write degrades the transcript and does not swallow the answer.
    test "a message store that refuses the write does not fail a keyless turn" do
      Concierge.config.chat_factory = lambda do |model:, chat_record: nil|
        chat_record.define_singleton_method(:add_message) do |*|
          raise ActiveRecord::RecordNotSaved, "no room at the inn"
        end
        Dummy::ScriptedChat.new(chat_record)
      end

      result = without_provider_credentials { Concierge::Run.reactive(@csm, "how do I publish?") }

      assert result.ok?, "a host storage failure took the offline reply down with it"
      assert_includes result.reply_text, "Changelog"
      assert_equal :not_persisted, result.run_record.reply_unavailable_reason
    end

    private

    def transcript
      Message.order(:id).map { |m| [ m.role.to_s, m.content.to_s ] }
    end
  end
end
