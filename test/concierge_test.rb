require "test_helper"

class ConciergeTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert Concierge::VERSION
  end

  test "configure yields the singleton configuration" do
    Concierge.configure { |c| c.default_model = "claude-sonnet-4-5" }
    assert_equal "claude-sonnet-4-5", Concierge.config.default_model
  end

  test "reset_config! restores defaults" do
    Concierge.config.default_model = "x"
    Concierge.reset_config!
    assert_nil Concierge.config.default_model
    assert_equal "Chat", Concierge.config.chat_model_name
  end

  test "host models are available in the dummy app" do
    tenant = Tenant.create!(name: "Acme", plan: "pro")
    user = tenant.users.create!(email: "a@acme.test")
    assert_equal tenant, user.tenant
  end

  test "RubyLLM acts_as chat models are installed in the dummy app" do
    assert defined?(Chat)
    assert Chat.new.respond_to?(:to_llm)
  end

  test "FakeChat records instructions and returns the scripted reply" do
    Concierge::Test::FakeChat.script(reply: "Hello!")
    chat = Concierge.config.chat_factory.call(model: "m", chat_record: nil)
    chat.with_instructions("system prompt here")
    reply = chat.ask("hi")
    assert_equal "Hello!", reply.content
    assert_includes chat.system_prompt, "system prompt here"
    assert_equal "hi", chat.prompts.last
  end
end
