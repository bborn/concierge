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

  test "the memory list shows which agent owns each note" do
    Concierge.config.authenticate_admin = ->(_c) { true }
    Concierge::Test.configure_agents!
    subject = Concierge.config.account.build(@tenant)
    Concierge::ContextStore.new.remember(
      Concierge::Scope.new(Concierge.config.agent(:billing), subject),
      body: "card on file expires in March"
    )

    get "/concierge/admin/memories"

    assert_response :success
    assert_select "th", "Agent"
    assert_select "td", "billing"
  end

  test "the agents screen lists every declared agent with its six slots" do
    Concierge.config.authenticate_admin = ->(_c) { true }
    Concierge::Test.configure_agents!

    get "/concierge/admin/agents"

    assert_response :success
    %w[csm billing Kit Bill].each { |text| assert_includes response.body, text }
    assert_includes response.body, "money.refund"        # billing's authority envelope
    assert_includes response.body, "RecallTool (read)"   # its tool scope
    assert_includes response.body, Concierge::Scope::SHARED
  end

  test "the agents screen shows an un-pluralized host as the implicit csm agent" do
    Concierge.config.authenticate_admin = ->(_c) { true }

    get "/concierge/admin/agents"

    assert_response :success
    assert_includes response.body, "csm"
    refute_includes response.body, "billing"
  end

  test "the agents screen fails closed like every other admin screen" do
    get "/concierge/admin/agents"
    assert_response :forbidden
  end
end
