require "test_helper"

class ChatWidgetTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
  end

  test "posting a message returns the agent's reply" do
    Concierge::Test::FakeChat.script(reply: "Happy to help!")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "how do I publish?" }

    assert_response :success
    assert_equal "Happy to help!", response.parsed_body["reply"]
  end

  test "a failed run returns a graceful error" do
    Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :service_unavailable
  end
end
