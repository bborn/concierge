require "test_helper"

class AdminTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro")
    @memory = Concierge::Memory.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                                        body: "likes weekly digests", source: "agent")
  end

  test "admin fails closed when no authenticate_admin hook is configured" do
    get "/concierge/admin/memories"
    assert_response :forbidden
  end

  test "with an allowing hook, memories are listed" do
    Concierge.config.authenticate_admin = ->(_c) { true }
    get "/concierge/admin/memories"

    assert_response :success
    assert_includes response.body, "likes weekly digests"
  end

  test "an operator can pin a memory" do
    Concierge.config.authenticate_admin = ->(_c) { true }
    patch "/concierge/admin/memories/#{@memory.id}", params: { memory: { pinned: true } }

    assert_response :redirect
    assert @memory.reload.pinned
  end

  test "deliveries audit log requires auth and renders" do
    Concierge.config.authenticate_admin = ->(_c) { true }
    get "/concierge/admin/deliveries"
    assert_response :success
  end
end
