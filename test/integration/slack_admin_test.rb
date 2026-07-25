require "test_helper"

# The Slack side of the queue, in the surface that does not depend on Slack (design
# §10.7). This screen exists so an outage — or a suppressed card, or a failed post —
# is visible rather than something an operator finds out by scrolling a channel.
class SlackAdminTest < ActionDispatch::IntegrationTest
  setup do
    Concierge::Test.configure_agents!
    Concierge.config.authenticate_admin = ->(_c) { true }
    Concierge.config.admin_actor        = ->(_c) { "sam@acme.test" }
    @transport = Concierge::Test.configure_slack!

    @tenant = Tenant.create!(name: "Acme", plan: "pro")
    @tenant.users.create!(email: "dana@acme.test")
    @subject = Concierge.config.account.build(@tenant)
    @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
  end

  test "the Slack screen fails closed like every other admin screen" do
    Concierge.config.authenticate_admin = nil

    get "/concierge/admin/slack"

    assert_response :forbidden
  end

  test "it shows one channel per agent, the cap, and today's volume against it" do
    propose

    get "/concierge/admin/slack"

    assert_response :success
    assert_includes response.body, "C0BILLING"
    assert_includes response.body, "C0CSM"
    assert_includes response.body, "/concierge/slack/interactions"
    assert_includes response.body, "billing"
  end

  test "a suppressed card is visible here, and says the decision is still available" do
    @transport = Concierge::Test.configure_slack!(cap: 0)
    propose

    get "/concierge/admin/slack"

    assert_response :success
    assert_includes response.body, "suppressed"
    assert_includes response.body, "over the daily cap"
  end

  test "a card that could not be posted names the failure" do
    @transport.fail_with = Concierge::Slack::ApiError.new("channel_not_found")
    propose

    get "/concierge/admin/slack"

    assert_response :success
    assert_includes response.body, "channel_not_found"
  end

  test "an unconfigured Slack says so instead of looking healthy" do
    Concierge.reset_config!
    Concierge::Test.configure!
    Concierge::Test.configure_agents!
    Concierge.config.authenticate_admin = ->(_c) { true }

    get "/concierge/admin/slack"

    assert_response :success
    assert_includes response.body, "concierge-flash--alert"
    assert_includes response.body, "No Slack signing secret is configured"
  end

  test "the proposals queue says whether a proposal is also carded" do
    propose

    get "/concierge/admin/proposals"

    assert_response :success
    assert_includes response.body, "carded in"
  end

  test "the proposals queue tells an operator when the cap swallowed the card" do
    # The property that makes the outage story true: the decision is here either
    # way, and the screen says the notification is the thing that went missing.
    @transport = Concierge::Test.configure_slack!(cap: 0)
    propose

    get "/concierge/admin/proposals"

    assert_response :success
    assert_includes response.body, "over its daily card cap"
    assert_includes response.body, "Approve"
  end

  private

  def propose
    Concierge::Proposal.propose(@billing, action_class: "record.plan_change",
                                          payload: { "from" => "pro", "to" => "enterprise" },
                                          idempotency_key: "plan-1")
  end
end
