require "test_helper"

# The Slack side of the queue, in the surface that does not depend on Slack (design
# §10.7). This screen exists so an outage — or a suppressed card, or a failed post —
# is visible rather than something an operator finds out by scrolling a channel.
class SlackAdminTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Concierge::Test::BrokenQueue

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

  test "the proposals queue says a Slack-queued execution is queued, not undispatched" do
    # The queue is not the surface that queued this. A Slack Approve hands the
    # doing to Concierge::ProposalExecutionJob (§10.7) and tells its own card so
    # with +executing:+ — a flag this screen will never be passed. Without the
    # stamp on the row the proposal reads "approved, not yet dispatched", which is
    # what a proposal nobody handed to anything reads, and an operator watching a
    # slow executor cannot tell "running right now" from "stuck, needs a Retry".
    proposal = propose

    assert_enqueued_with(job: Concierge::ProposalExecutionJob) do
      Concierge::Slack::Intake.handle(approve_click(proposal))
    end

    get "/concierge/admin/proposals"

    assert_response :success
    assert_includes response.body, "queued to be performed at"
    refute_includes response.body, "approved, not yet dispatched"
  end

  test "the queue stops promising an execution once the job has an answer" do
    # The other half of the same honesty: a stamp nothing clears is a screen that
    # says "any moment now" forever. Proposal::Execute clears it on every outcome.
    Concierge.configure do |c|
      c.proposals do
        execute("record.plan_change") { |p, scope| scope.subject.to_model.update!(plan: p.action_arguments[:to]) }
      end
    end
    proposal = propose
    Concierge::Slack::Intake.handle(approve_click(proposal))
    perform_enqueued_jobs

    get "/concierge/admin/proposals"

    assert_response :success
    assert_equal "executed", proposal.reload.state
    refute_includes response.body, "queued to be performed at"
  end

  test "an execution that could not be queued is not reported as queued" do
    # The one path that must not stamp. hand_off_execution answers +:failed+ when
    # the enqueue raises, and there is then no job to clear anything — so a stamp
    # left behind would have this screen promising, for good, a run that was never
    # scheduled. That is the exact under-reporting the stamp exists to end, in
    # reverse.
    proposal = propose

    with_broken_queue do
      Concierge::Slack::Intake.handle(approve_click(proposal))
    end

    proposal.reload
    assert_equal "approved", proposal.state, "the decision must stay durable"
    refute proposal.execution_queued?

    get "/concierge/admin/proposals"

    assert_response :success
    assert_includes response.body, "approved, not yet dispatched"
    refute_includes response.body, "queued to be performed at"
  end

  private

  def approve_click(proposal)
    card = Concierge::SlackCard.find_by(agent_proposal_id: proposal.id)
    { "type" => "block_actions", "user" => { "id" => "U9" },
      "container" => { "channel_id" => card.channel_id, "message_ts" => card.thread_ts },
      "message" => { "ts" => card.thread_ts },
      "actions" => [ { "action_id" => Concierge::Slack::Card::APPROVE,
                       "value" => proposal.id.to_s } ] }
  end

  def propose
    Concierge::Proposal.propose(@billing, action_class: "record.plan_change",
                                          payload: { "from" => "pro", "to" => "enterprise" },
                                          idempotency_key: "plan-1")
  end
end
