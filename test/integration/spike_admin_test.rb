require "test_helper"

# The throwaway spike screen: the gate's evidence rendered on one page.
class SpikeAdminTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
    @tenant.users.create!(email: "dana@acme.test")
    Concierge.config.authenticate_admin = ->(_c) { true }
  end

  test "the spike screen does not exist unless the flag is on" do
    get "/concierge/admin/spike"
    assert_response :not_found
  end

  test "it still fails closed on auth, flag or no flag" do
    Concierge::Test.configure_agents!
    Concierge.config.authenticate_admin = nil

    get "/concierge/admin/spike"
    assert_response :forbidden
  end

  test "it lists both agents with their six slots" do
    Concierge::Test.configure_agents!
    get "/concierge/admin/spike"

    assert_response :success
    assert_includes response.body, "csm"
    assert_includes response.body, "billing"
    assert_includes response.body, "Kit"
    assert_includes response.body, "Bill"
    assert_includes response.body, "money.refund"
    assert_includes response.body, "human_execution"
    assert_includes response.body, "RoutineTool"
  end

  test "running every agent records one provenance row per agent" do
    Concierge::Test.configure_agents!
    Concierge::Test::FakeChat.script(reply: "ok")

    post "/concierge/admin/spike/runs", params: { subject_id: @tenant.id }
    assert_redirected_to "/concierge/admin/spike"

    assert_equal %w[billing csm], Concierge::Spike::Provenance.recent.map(&:agent_slug).sort

    follow_redirect!
    assert_includes response.body, "proactive"
  end
end
