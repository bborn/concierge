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
  end
end
