require "test_helper"

class ChatWidgetTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
    # The subject of these tests is the turn, not the gate: say the host said yes
    # once, here, rather than in the baseline config — see
    # Concierge::Test.authorize_all_subjects!.
    Concierge::Test.authorize_all_subjects!
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

  test "an omitted agent parameter answers as the default agent" do
    Concierge::Test.configure_agents!
    Concierge::Test::FakeChat.script(reply: "Kit here.")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :success
    assert_equal "csm", response.parsed_body["agent"]
  end

  test "the agent parameter picks which business function answers" do
    Concierge::Test.configure_agents!
    Concierge::Test::FakeChat.script(reply: "Bill here.")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi", agent: "billing" }

    assert_response :success
    assert_equal "billing", response.parsed_body["agent"]
    assert_includes Concierge::Test::FakeChat.current.system_prompt, "Bill"
  end

  test "an agent no host declared is a 404, not a silent fall-back to the CSM" do
    Concierge::Test.configure_agents!
    Concierge::Test::FakeChat.script(reply: "should never run")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi", agent: "nope" }

    assert_response :not_found
    assert_equal 0, Concierge::Conversation.count
  end
end
