require "test_helper"

# The two endpoints a real Slack app needs (design §10.7), over real HTTP with real
# signatures. The signature is *not* stubbed out anywhere in this file: an endpoint
# that can be driven without one is the whole vulnerability, and a test that skipped
# it would be the crutch that hides a missing check.
class SlackEndpointsTest < ActionDispatch::IntegrationTest
  include Concierge::Test::SlackRequests

  setup do
    Concierge::Test.configure_agents!
    @transport = Concierge::Test.configure_slack!

    @tenant = Tenant.create!(name: "Acme", plan: "pro")
    @tenant.users.create!(email: "dana@acme.test")
    @subject = Concierge.config.account.build(@tenant)
    @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

    Concierge.configure do |c|
      c.proposals do
        execute("record.plan_change") { |proposal, scope| scope.subject.to_model.update!(plan: proposal.action_arguments[:to]) }
      end
    end
  end

  test "the URL handshake is answered with the challenge" do
    body = JSON.generate(type: "url_verification", challenge: "3eZbrw1a")

    post "/concierge/slack/events", params: body, headers: slack_headers(body)

    assert_response :success
    assert_equal "3eZbrw1a", JSON.parse(response.body)["challenge"]
  end

  test "an unsigned request is refused and changes nothing" do
    proposal = propose
    body = interaction_body(proposal)

    post "/concierge/slack/interactions", params: { payload: body },
         headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

    assert_response :unauthorized
    assert_equal "proposed", proposal.reload.state
  end

  test "a request signed with the wrong secret is refused and changes nothing" do
    proposal = propose
    body = "payload=#{CGI.escape(interaction_body(proposal))}"

    post "/concierge/slack/interactions", params: body,
         headers: slack_form_headers(body, secret: "not-the-signing-secret")

    assert_response :unauthorized
    assert_equal "proposed", proposal.reload.state
  end

  test "a replayed payload is refused even though its signature is valid" do
    proposal = propose
    body = "payload=#{CGI.escape(interaction_body(proposal))}"
    stale = Time.current.to_i - (Concierge::Slack::Signature::REPLAY_WINDOW + 60)

    post "/concierge/slack/interactions", params: body,
         headers: slack_form_headers(body, timestamp: stale)

    assert_response :unauthorized
    assert_equal "proposed", proposal.reload.state
  end

  test "a signed Approve click decides the proposal and executes it" do
    proposal = propose
    body = "payload=#{CGI.escape(interaction_body(proposal))}"

    post "/concierge/slack/interactions", params: body, headers: slack_form_headers(body)

    assert_response :success
    proposal.reload
    assert_equal "executed", proposal.state
    assert_equal "slack:U77", proposal.approved_by
    assert_equal "enterprise", @tenant.reload.plan
  end

  test "a modal submission answers Slack with the validation error, not a 500" do
    proposal = propose
    payload = {
      type: "view_submission", user: { id: "U77" },
      view: { callback_id: Concierge::Slack::Card::REJECT_MODAL,
              private_metadata: JSON.generate(proposal_id: proposal.id),
              state: { values: { Concierge::Slack::Card::REASON_BLOCK =>
                                   { Concierge::Slack::Card::INPUT_ACTION => { value: " " } } } } }
    }
    body = "payload=#{CGI.escape(JSON.generate(payload))}"

    post "/concierge/slack/interactions", params: body, headers: slack_form_headers(body)

    assert_response :success
    assert_equal "errors", JSON.parse(response.body)["response_action"]
    assert_equal "proposed", proposal.reload.state
  end

  test "a reply in a case thread is captured against that case" do
    proposal = propose
    card = Concierge::SlackCard.find_by(agent_proposal_id: proposal.id)
    body = JSON.generate(
      type: "event_callback",
      event: { type: "message", channel: card.channel_id, thread_ts: card.thread_ts,
               user: "U77", text: "Hold this until their finance review." }
    )

    post "/concierge/slack/events", params: body, headers: slack_headers(body)

    assert_response :success
    assert_includes Concierge::Memory.for_scope(@billing).map(&:body),
                    "Hold this until their finance review."
  end

  test "without a signing secret the endpoints do not exist" do
    # Fail closed. Nothing can be signed, so nothing may be trusted — and an
    # endpoint that answered anything else would be advertising itself.
    Concierge.reset_config!
    Concierge::Test.configure!

    post "/concierge/slack/events", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found

    post "/concierge/slack/interactions", params: {}
    assert_response :not_found
  end

  test "the endpoints do not require a CSRF token, and the signature is why" do
    # Slack cannot send one. The signature is the authentication and it is checked
    # on every request before a single byte of the payload is read.
    with_forgery_protection do
      proposal = propose
      body = "payload=#{CGI.escape(interaction_body(proposal))}"

      post "/concierge/slack/interactions", params: body, headers: slack_form_headers(body)

      assert_response :success
      assert_equal "executed", proposal.reload.state
    end
  end

  private

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  def propose
    Concierge::Proposal.propose(@billing, action_class: "record.plan_change",
                                          payload: { "from" => "pro", "to" => "enterprise" },
                                          idempotency_key: "plan-1")
  end

  def interaction_body(proposal, action_id: Concierge::Slack::Card::APPROVE)
    card = Concierge::SlackCard.find_by(agent_proposal_id: proposal.id)
    JSON.generate(
      type: "block_actions",
      user: { id: "U77" },
      trigger_id: "T1",
      container: { channel_id: card&.channel_id, message_ts: card&.message_ts },
      actions: [ { action_id: action_id, value: proposal.id.to_s } ]
    )
  end
end
