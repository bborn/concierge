require "test_helper"

# The *customer* half of the host-authorization seam for the engine's
# per-account endpoints (config.authorize_subject, Concierge::ScopedEndpoint):
# "is this account yours". The staff half — config.authorize_operator, and the
# fact that neither hook answers the other's question — is
# test/integration/operator_authorization_test.rb.
#
# The *isolation* consequence — one account cannot reach another's — is asserted
# where it belongs, in test/integration/host_isolation_test.rb against a real
# signed-in host session. This file is the hook itself: what it is handed, what
# it may answer, and what happens to a host that never sets it.
class SubjectAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
  end

  # --- Fails closed, like the admin ------------------------------------------

  test "the chat endpoint is refused when no hook is configured" do
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :forbidden
    assert_equal "not authorized for this account", response.parsed_body["error"]
    assert_empty Concierge::Test::FakeChat.current.prompts
    assert_equal 0, Concierge::Conversation.count
  end

  test "the handoff endpoints are refused when no hook at all is configured" do
    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }
    assert_response :forbidden

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Sam here." }
    assert_response :forbidden

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :forbidden

    assert_equal 0, Concierge::Handoff.count
    assert_equal 0, Concierge::Memory.count
  end

  test "the refusal says which hook is missing, and how to set it" do
    log = StringIO.new
    Concierge.config.logger = Logger.new(log)

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :forbidden
    assert_includes log.string, "ERROR"
    assert_includes log.string, "config.authorize_subject"
    assert_includes log.string, "Refused a request for an account"
  end

  # --- What the hook is handed ------------------------------------------------

  test "the hook is handed the controller and the resolved (agent, account) scope" do
    Concierge::Test.configure_agents!
    seen = nil
    Concierge.configure do |c|
      c.authorize_subject = ->(controller, scope) { seen = [ controller, scope ]; true }
    end
    Concierge::Test::FakeChat.script(reply: "Bill here.")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi", agent: "billing" }

    assert_response :success
    controller, scope = seen
    assert_kind_of Concierge::ChatsController, controller
    assert_respond_to controller, :session
    assert_equal "billing", scope.agent_slug
    assert_equal @tenant.id.to_s, scope.subject.id.to_s
    assert_equal "Acme", scope.subject[:name]
  end

  test "the answer can be per business function, not only per account" do
    # Which is why the hook is handed the Scope and not the bare Subject: "this
    # person may talk to the CSM but not to billing" is a real host policy.
    Concierge::Test.configure_agents!
    Concierge.configure do |c|
      c.authorize_subject = ->(_controller, scope) { scope.agent_slug == "csm" }
    end

    Concierge::Test::FakeChat.script(reply: "Kit here.")
    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi", agent: "csm" }
    assert_response :success

    Concierge::Test::FakeChat.script(reply: "should never be reached")
    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi", agent: "billing" }
    assert_response :forbidden
    assert_empty Concierge::Test::FakeChat.current.prompts
  end

  test "a hook that says yes lets the chat endpoint through unchanged" do
    Concierge::Test.authorize_all_subjects!
    Concierge::Test::FakeChat.script(reply: "Kit here.")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :success
    assert_equal "Kit here.", response.parsed_body["reply"]
  end

  # --- What the gate does not cover -------------------------------------------

  test "an unsubscribe link still works without the hook, because the token is the authorization" do
    # Over-applying the gate would break the one surface whose whole point is
    # that the person following it is not signed in.
    subject = Concierge.config.account.build(@tenant)
    Concierge::Outreach.deliver(Concierge::Result.new(reply_text: "hi"), subject, channel: :in_app)
    token = Concierge::ChannelDelivery.for_subject(subject).last.unsubscribe_token

    get "/concierge/unsubscribe/#{token}"

    assert_response :success
    assert Concierge::OutreachPreference.for(subject).opted_out
  end

  test "a subject's display label is not a way to reach it through the endpoint" do
    # config.subject_label is a caption for the admin and the Slack cards, never
    # an identifier. Even with the host answering yes to everything, the URL
    # still takes an id: a label that resolved here would be host display text
    # promoted to a key, and forgeable by whoever can type it.
    Concierge::Test.authorize_all_subjects!
    Concierge.config.subject_label = ->(_ref) { "Crossroads Commons" }
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    post "/concierge/accounts/Crossroads%20Commons/chat", params: { message: "hi" }

    assert_response :forbidden
    assert_empty Concierge::Test::FakeChat.current.prompts
    assert_equal 0, Concierge::Conversation.count
  end

  test "the admin keeps its own hook rather than answering to this one" do
    # Two different questions: authenticate_admin is "are you staff", and
    # authorize_subject is "is this account yours". Neither may stand in for the
    # other.
    Concierge::Test.authorize_all_subjects!

    get "/concierge/admin/runs"

    assert_response :forbidden
  end
end
