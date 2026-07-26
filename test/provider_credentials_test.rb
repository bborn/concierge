require "test_helper"

module Concierge
  class ProviderCredentialsTest < ActiveSupport::TestCase
    test "reports a credentialed provider as configured" do
      assert ProviderCredentials.configured?(provider: :anthropic)
    end

    test "reports an uncredentialed provider as unconfigured" do
      without_provider_credentials do
        refute ProviderCredentials.configured?(provider: :anthropic)
      end
    end

    # The check has to answer *without* building the provider, because building
    # it is the thing that raises. If this ever regressed into instantiation the
    # call itself would blow up rather than return false.
    test "answering for an uncredentialed provider does not raise" do
      without_provider_credentials do
        assert_nothing_raised { ProviderCredentials.configured?(provider: :anthropic) }
      end
    end

    test "infers the provider from a bare model id" do
      assert_equal "anthropic", ProviderCredentials.provider_for("claude-sonnet-4-5")

      without_provider_credentials do
        refute ProviderCredentials.configured?(model: "claude-sonnet-4-5")
      end
    end

    # Concierge only speaks up about providers it can identify. Anything else is
    # RubyLLM's to explain, with its own far clearer error.
    test "declines to have an opinion about unknown providers and models" do
      assert ProviderCredentials.configured?(provider: :not_a_real_provider)
      assert ProviderCredentials.configured?(model: "not-a-real-model")
      assert ProviderCredentials.configured?
    end

    # A host with no default_provider still gets the check, via the model id —
    # OpenAI has no key in this suite, deliberately.
    test "an unset provider is resolved through the model rather than skipped" do
      assert_nil ENV["OPENAI_API_KEY"]
      refute ProviderCredentials.configured?(model: "gpt-4.1-nano")
    end
  end
end
