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

    test "an uncredentialed provider yields no chat record and no conversation" do
      without_provider_credentials do
        assert_nil ChatResolver.call(@subject)
      end

      assert_equal 0, Conversation.for_subject(@subject).count,
                   "a conversation was recorded pointing at a Chat that was never created"
    end

    # The degrade is scoped to record creation, not to the config: the moment
    # credentials appear, the same host persists conversations again.
    test "credentials appearing later restore persistence" do
      without_provider_credentials { ChatResolver.call(@subject) }

      chat = ChatResolver.call(@subject)

      assert chat.persisted?
      assert_equal "anthropic", chat.provider
      assert_equal 1, Conversation.for_subject(@subject).count
    end

    # Regression: the degrade above is only as good as the gate that fires it, and
    # the gate asks ProviderCredentials, which answers through the model id. On a
    # real Rails host (acts_as_model) RubyLLM prefers the host's `models` table
    # the moment it has a row, and that table holds only the models the host has
    # already talked to — so the gate's lookup started failing, "unknown model"
    # was read as "credentials are fine", and the degrade stopped firing. This
    # host has no key and a model its own table has never heard of; it must still
    # degrade, and it must not raise RubyLLM::ModelNotFoundError out of a
    # before_save on the way — which is exactly what it did.
    #
    # default_provider is nil deliberately. It is a documented, supported setting
    # ("leave nil to let RubyLLM resolve the model normally"), and it is what puts
    # the whole gate on the model lookup: a host that names its provider is asked
    # about that provider directly and never reached this. So the bug was invisible
    # to every test in this suite, all of which inherit the dummy's :anthropic.
    test "the degrade still fires when the host's registry is partial" do
      Concierge.config.default_provider = nil

      with_partial_model_registry("gpt-4.1-nano" => "openai") do
        without_provider_credentials do
          assert_nothing_raised { ChatResolver.call(@subject) }
          assert_nil ChatResolver.call(@subject)
        end
      end

      assert_equal 0, Conversation.for_subject(@subject).count,
                   "a conversation was recorded pointing at a Chat that was never created"
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
