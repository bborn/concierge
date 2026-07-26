require "test_helper"

# The *staff* half of the host-authorization seam (config.authorize_operator,
# Concierge::ScopedEndpoint). The customer half is
# test/integration/subject_authorization_test.rb.
#
# The engine's handoff endpoints seize a customer's thread, speak on it as the
# company, and land what is said as pinned human-sourced memory in that agent's
# namespace. Until this change they shared the chat endpoint's hook, so the
# question they asked was "is this account yours" — which a customer answers yes
# about their own account. Everything below is that distinction: two questions,
# two hooks, and neither standing in for the other in either direction.
class OperatorAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
    @subject = Concierge.config.account.build(@tenant)
  end

  # --- Fails closed, and does not inherit an answer ---------------------------

  test "the operator endpoints are refused when only the customer hook is set" do
    # The regression. A host that writes the obvious tenant-match hook — the one
    # in the README and in this dummy app — has answered "is this account yours"
    # and nothing else. That must not be read as "and you are staff".
    Concierge::Test.authorize_all_subjects!

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "not-really-support" }
    assert_response :forbidden

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Support here." }
    assert_response :forbidden

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :forbidden

    assert_equal 0, Concierge::Handoff.count
    assert_equal 0, Concierge::Memory.count,
                 "a refused operator message still wrote human-sourced memory"
  end

  test "the refusal says which hook is missing, and that it is not the other one" do
    Concierge::Test.authorize_all_subjects!
    log = StringIO.new
    Concierge.config.logger = Logger.new(log)

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }

    assert_response :forbidden
    assert_includes log.string, "ERROR"
    assert_includes log.string, "config.authorize_operator"
    assert_includes log.string, "are you staff"
    assert_includes log.string, "separate hook"
  end

  test "the customer hook does not open the operator endpoints even when it inspects the request" do
    # A host *could* have written the staff clause inside authorize_subject —
    # that was the old advice. It no longer matters what it says: the operator
    # endpoints do not ask it at all, so a permissive one cannot leak into them.
    asked = []
    Concierge.configure do |c|
      c.authorize_subject = ->(controller, _scope) { asked << controller.request.path; true }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }

    assert_response :forbidden
    assert_empty asked, "the operator endpoint consulted the customer hook"
  end

  # --- ...and not in the other direction either -------------------------------

  test "the operator hook does not open the chat endpoint" do
    Concierge::Test.authorize_all_operators!
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :forbidden
    assert_equal "not authorized for this account", response.parsed_body["error"]
    assert_empty Concierge::Test::FakeChat.current.prompts
  end

  # --- What the operator hook is handed ---------------------------------------

  test "the hook is handed the controller and the resolved (agent, account) scope" do
    Concierge::Test.configure_agents!
    seen = nil
    Concierge.configure do |c|
      c.authorize_operator = ->(controller, scope) { seen = [ controller, scope ]; true }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "billing" }

    assert_response :created
    controller, scope = seen
    assert_kind_of Concierge::HandoffsController, controller
    assert_respond_to controller, :session
    assert_equal "billing", scope.agent_slug
    assert_equal @tenant.id.to_s, scope.subject.id.to_s
  end

  test "an operator can be staff for one business function and not another" do
    # "Only the billing team may take the billing thread" is a real staffing
    # policy, which is why this hook is handed the Scope and not the subject.
    Concierge::Test.configure_agents!
    Concierge.configure do |c|
      c.authorize_operator = ->(_controller, scope) { scope.agent_slug == "billing" }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "billing" }
    assert_response :created

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "csm" }
    assert_response :forbidden

    assert_nil Concierge::Handoff.active_for(
      Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    )
  end

  test "a hook that says yes lets the whole takeover through" do
    Concierge::Test.authorize_all_operators!

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }
    assert_response :created
    assert Concierge::Handoff.active_for(@subject)

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Hi, this is Sam." }
    assert_response :ok
    assert_equal "human", Concierge::Memory.for_subject(@subject).first.source

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :no_content
    assert_nil Concierge::Handoff.active_for(@subject)
  end

  test "an account that does not exist is refused the same way an unstaffed one is" do
    Concierge::Test.authorize_all_operators!

    delete "/concierge/accounts/#{Tenant.maximum(:id) + 1}/handoff"

    assert_response :forbidden
  end
end
