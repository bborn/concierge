require "test_helper"

class HandoffFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
    @subject = Concierge.config.account.build(@tenant)
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
end
