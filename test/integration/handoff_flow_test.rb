require "test_helper"

class HandoffFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
    @subject = Concierge.config.account.build(@tenant)
    # These endpoints fail closed without config.authorize_operator — the *staff*
    # hook, not the customer one the chat endpoint asks. The gate itself is
    # asserted in test/integration/operator_authorization_test.rb and
    # test/integration/host_isolation_test.rb. Here the subject is the takeover.
    Concierge::Test.authorize_all_operators!
  end

  test "an operator can seize, send as human, and release a thread over HTTP" do
    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }
    assert_response :created
    assert Concierge::Handoff.active_for(@subject)

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Hi, this is Sam from support." }
    assert_response :ok
    assert_equal "human", Concierge::Memory.for_subject(@subject).first.source

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :no_content
    assert_nil Concierge::Handoff.active_for(@subject)
  end

  test "a takeover of one agent's thread leaves the other agent's alone" do
    Concierge::Test.configure_agents!
    billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "billing" }
    assert_response :created

    assert Concierge::Handoff.active_for(billing)
    assert_nil Concierge::Handoff.active_for(csm)

    post "/concierge/accounts/#{@tenant.id}/handoff/message",
         params: { body: "Sam here about invoice #4471.", agent: "billing" }
    assert_response :ok

    # The operator's correction steers billing, not every business function.
    assert_equal 1, Concierge::Memory.for_scope(billing).count
    assert_equal 0, Concierge::Memory.for_scope(csm).count
  end
end
