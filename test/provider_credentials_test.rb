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

    # --- A partial registry is not a licence to assume credentials ---
    #
    # The check answers through the model id, so what it can resolve decides what
    # it can refuse. RubyLLM memoizes one registry per process and prefers the
    # host's `models` table the moment that table has a row (acts_as_model wires
    # the source up at class-definition time). That table holds only the models
    # the host has actually talked to — so on a real Rails host Models.find
    # raises for nearly every model, which used to mean "unknown model, assume
    # configured": credentials-are-fine for a host with no key at all.

    test "resolves a model this host's registry does not hold" do
      with_partial_model_registry("claude-sonnet-4-5" => "anthropic") do
        # Precondition: the host's own registry genuinely cannot answer this.
        assert_raises(RubyLLM::ModelNotFoundError) { RubyLLM.models.find("gpt-4.1-nano") }

        assert_equal "openai", ProviderCredentials.provider_for("gpt-4.1-nano")
      end
    end

    test "a partial registry does not turn an uncredentialed host into a configured one" do
      with_partial_model_registry("gpt-4.1-nano" => "openai") do
        without_provider_credentials do
          refute ProviderCredentials.configured?(model: "claude-sonnet-4-5"),
                 "a host with no Anthropic key was reported as credentialed"
        end
      end
    end

    # The same question, asked of the provider the model resolves to rather than
    # one the caller named: OpenAI has no key in this suite, and a registry that
    # cannot name OpenAI must not be read as "no OpenAI needed".
    test "a partial registry does not hide a missing key for another provider" do
      with_partial_model_registry("claude-sonnet-4-5" => "anthropic") do
        assert_nil ENV["OPENAI_API_KEY"]
        refute ProviderCredentials.configured?(model: "gpt-4.1-nano")
      end
    end

    # The distinction the fix turns on: "not in this host's table" is answerable
    # from RubyLLM's bundled data, but a model id RubyLLM has never heard of is
    # genuinely unknown, and there the deliberate true still stands — a host with
    # a typo'd model id wants RubyLLM's "Unknown model:" error, not a silent
    # degrade that never mentions the typo.
    test "still declines to have an opinion about a model RubyLLM itself does not know" do
      with_partial_model_registry("claude-sonnet-4-5" => "anthropic") do
        assert_nil ProviderCredentials.provider_for("not-a-real-model")

        without_provider_credentials do
          assert ProviderCredentials.configured?(model: "not-a-real-model")
        end
      end
    end

    # Asking must not repair, replace, or otherwise disturb the registry the host
    # chose. Concierge reads RubyLLM's bundled data as its *own* second opinion;
    # a check that quietly swapped the process-wide registry would change which
    # models the host's own acts_as_chat can resolve.
    test "answering does not disturb the host's own registry" do
      with_partial_model_registry("claude-sonnet-4-5" => "anthropic") do
        before = RubyLLM::Models.instance

        ProviderCredentials.configured?(model: "gpt-4.1-nano")

        assert_same before, RubyLLM::Models.instance
        assert_equal 1, RubyLLM.models.all.size
        assert_raises(RubyLLM::ModelNotFoundError) { RubyLLM.models.find("gpt-4.1-nano") }
      end
    end
  end
end
