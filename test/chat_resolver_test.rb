require "test_helper"

module Concierge
  class ChatResolverTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "creates a persistent Chat pinned to the configured model" do
      chat = ChatResolver.call(@subject)

      assert chat.persisted?
      assert_equal "claude-sonnet-4-5", chat.model_id
      assert_equal "anthropic", chat.provider
    end

    test "resolves the same Chat on a second call (one conversation per subject)" do
      first  = ChatResolver.call(@subject)
      second = ChatResolver.call(@subject)

      assert_equal first.id, second.id
      assert_equal 1, Conversation.for_subject(@subject).count
    end

    # Regression: creating a Chat with no model let RubyLLM fall back to its
    # *global* default provider (OpenAI), demanding an OPENAI_API_KEY even for an
    # Anthropic-only host. The whole suite runs with only ANTHROPIC_API_KEY set,
    # so a regression here surfaces as a missing-OpenAI-key ConfigurationError.
    test "does not require credentials for a provider Concierge doesn't use" do
      assert_nil ENV["OPENAI_API_KEY"]
      assert_nothing_raised { ChatResolver.call(@subject) }
    end

    # Regression: the documented offline path. Creating the Chat *record* made
    # acts_as_chat resolve a model, and Models.resolve instantiates the provider
    # before it honours assume_exists — so a host with no API key raised
    # RubyLLM::ConfigurationError out of a before_save and never reached its own
    # scripted chat_factory. Assuming the model exists cannot help; neither can
    # leaving the provider unset (the other branch of resolve instantiates too).
    test "resolves without credentials instead of raising" do
      without_provider_credentials do
        assert_nothing_raised { ChatResolver.call(@subject) }
      end
    end

    # Regression (task 5017): the answer to the paragraph above used to be "then
    # no conversation at all", which left every host-transcript surface — the
    # widget's tool-call strip, the run screen's question and reply — permanently
    # empty on a keyless host. The engine now owns the resolution instead of the
    # before_save, so the record is created and the credential is never consulted.
    test "an uncredentialed provider still gets a persisted conversation" do
      chat = without_provider_credentials { ChatResolver.call(@subject) }

      assert chat.persisted?, "a keyless host was handed no host Chat"
      assert_equal "claude-sonnet-4-5", chat.model_id
      assert_equal "anthropic", chat.provider
      assert_equal 1, Conversation.for_subject(@subject).count
    end

    # ...and it is a real conversation, not a husk: the host can write the turn
    # into it, and read it back, with no provider anywhere in sight.
    test "a conversation opened without credentials accepts and keeps messages" do
      chat = without_provider_credentials do
        ChatResolver.call(@subject).tap do |record|
          record.add_message(role: :user, content: "what a keyless host asked")
        end
      end

      assert_equal [ "what a keyless host asked" ], chat.reload.messages.pluck(:content)
    end

    # The point of owning the resolution is that acts_as_chat's before_save has
    # nothing left to do — Models.resolve is the one call in it that builds a
    # provider, and it must never be reached. Stated directly, because on a
    # credentialed suite a regression to the string assignment would pass every
    # other test in this file: the credential would simply cover for it.
    test "creating the chat never reaches RubyLLM's own model resolution" do
      registry = RubyLLM::Models.singleton_class
      original = registry.instance_method(:resolve)
      registry.define_method(:resolve) do |*, **|
        raise "the before_save resolved the model, and built a provider doing it"
      end

      begin
        assert ChatResolver.call(@subject).persisted?
      ensure
        registry.define_method(:resolve, original)
      end
    end

    # Persistence no longer turns on credentials, so credentials coming back must
    # not open a *second* conversation for the same subject either.
    test "credentials appearing later continue the same conversation" do
      offline = without_provider_credentials { ChatResolver.call(@subject) }

      chat = ChatResolver.call(@subject)

      assert_equal offline.id, chat.id
      assert_equal "anthropic", chat.provider
      assert_equal 1, Conversation.for_subject(@subject).count
    end

    # Regression: on a real Rails host (acts_as_model) RubyLLM prefers the host's
    # `models` table the moment it has a row, and that table holds only the models
    # the host has already talked to — so a lookup for anything else raises
    # ModelNotFoundError. That used to surface out of a before_save; now the
    # lookup is ours, so it is ours to get right, and a partial registry must fall
    # back to RubyLLM's bundled data rather than failing the resolution.
    #
    # default_provider is nil deliberately. It is a documented, supported setting
    # ("leave nil to let RubyLLM resolve the model normally"), and it is what puts
    # the whole resolution on the model lookup: a host that names its provider
    # assumes the model exists and never reaches the registry at all. So this stays
    # invisible to every other test in this suite, all of which inherit the dummy's
    # :anthropic.
    test "a partial host registry still resolves, from RubyLLM's bundled data" do
      Concierge.config.default_provider = nil

      with_partial_model_registry("gpt-4.1-nano" => "openai") do
        without_provider_credentials do
          chat = assert_nothing_raised { ChatResolver.call(@subject) }

          assert chat.persisted?
          assert_equal "anthropic", chat.provider,
                       "the bundled registry knows this model's provider; the host's table does not"
        end
      end

      assert_equal 1, Conversation.for_subject(@subject).count
    end

    # ...and the same holds with the key present. Worth stating separately (task
    # 5018): the test above clears the credential, so it could be read as a claim
    # about the *offline* path, and the failure it guards was filed against a host
    # whose key was set. Nothing about the resolution turns on the credential —
    # which is the point, and is what this pins.
    test "a partial host registry resolves the same way with credentials present" do
      Concierge.config.default_provider = nil

      with_partial_model_registry("gpt-4.1-nano" => "openai") do
        chat = assert_nothing_raised { ChatResolver.call(@subject) }

        assert chat.persisted?
        assert_equal "claude-sonnet-4-5", chat.model_id
        assert_equal "anthropic", chat.provider
      end
    end

    # A model genuinely nobody has heard of is still an error, and RubyLLM's own
    # is the one that names it. Run turns it into a failed Result.
    test "a model neither registry knows raises RubyLLM's own error" do
      Concierge.config.default_provider = nil

      assert_raises(RubyLLM::ModelNotFoundError) do
        ChatResolver.call(@subject, model: "no-such-model-anywhere")
      end
    end

    # An existing conversation predates the credentials going away, so it still
    # resolves — losing the key must not orphan history a host already has.
    test "an already-persisted conversation still resolves without credentials" do
      persisted = ChatResolver.call(@subject)

      without_provider_credentials do
        assert_equal persisted.id, ChatResolver.call(@subject).id
      end
    end
  end
end
