require "test_helper"

# "Kit, take a look" — the proactive path on demand. Same code the weekly sweep
# runs; waiting a week is not a demo.
class HostAgentReviewTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup { sign_in_as @dana }

  test "a review lands in the customer's inbox and links its provenance" do
    Concierge::Test::FakeChat.script(reply: "You have a draft sitting there — want a hand?")

    post agent_review_path

    assert_redirected_to inbox_path
    assert_equal "Kit reviewed the account and sent you a message.", flash[:notice]

    message = @acme.inbox_messages.sole
    assert_equal "You have a draft sitting there — want a hand?", message.body
    assert_not message.read?

    run = Concierge::AgentRun.for_scope(csm_scope(@acme)).sole
    assert_equal "proactive", run.trigger
    assert_equal run.id, flash[:agent_run_id]

    follow_redirect!
    assert_select "a[href=?]", "/concierge/admin/runs", text: /run ##{run.id}/
  end

  test "a governed refusal is reported as a refusal, with the reason" do
    Concierge::OutreachPreference.create!(**csm_scope(@acme).subject.key, opted_out: true)
    Concierge::Test::FakeChat.script(reply: "Anything worth saying?")

    post agent_review_path

    assert_match(/decided not to send: this account has opted out/, flash[:notice])
    assert_equal 0, @acme.inbox_messages.count
  end

  test "the agent stands down while a human holds the thread" do
    Concierge::Handoff.seize!(csm_scope(@acme), operator: "support@acme.test")
    Concierge::Test::FakeChat.script(reply: "should never be sent")

    post agent_review_path

    assert_match(/stood down/, flash[:alert])
    assert_equal 0, @acme.inbox_messages.count
    assert_equal 0, Concierge::ChannelDelivery.for_scope(csm_scope(@acme)).count
  end

  test "a review runs for the signed-in account and nobody else" do
    Concierge::Test::FakeChat.script(reply: "Acme only.")

    post agent_review_path

    assert_equal 1, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@globex)).count
    assert_equal 0, @globex.inbox_messages.count
  end

  test "the control is not available outside a local environment" do
    original = Rails.env
    Rails.env = "production"

    post agent_review_path
    assert_response :forbidden
  ensure
    Rails.env = original
  end
end
