require "test_helper"

# Proactive outreach the customer never saw is outreach that did not happen, as
# far as the customer is concerned. The inbox is driven off the engine's own
# ChannelDelivery rows, one `for_scope` query per (agent, this account).
class HostInboxTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup { sign_in_as @dana }

  test "an in-app delivery reaches the customer, with an unread count in the header" do
    deliver_in_app(csm_scope(@acme), "Want a hand publishing your first entry?")

    get inbox_path

    assert_response :success
    assert_select ".msg__text", text: /Want a hand publishing/
    assert_select ".msg__who", text: "Kit"
    assert_select ".badge", text: "1"
  end

  test "both business functions land in the same inbox, under their own names" do
    deliver_in_app(csm_scope(@acme), "Publishing takes a minute.")
    deliver_in_app(billing_scope(@acme), "Your card expires in March.")

    get inbox_path

    assert_select ".msg__who", text: "Kit"
    assert_select ".msg__who", text: "Bill"
    assert_select ".badge", text: "2"
  end

  test "marking a message read clears it from the count" do
    deliver_in_app(csm_scope(@acme), "One thing worth a look.")
    message = @acme.inbox_messages.sole

    post read_inbox_message_path(message)

    assert_redirected_to inbox_path
    assert message.reload.read?
    follow_redirect!
    assert_select ".badge", count: 0
  end

  test "mark all read clears every unread message for this account only" do
    deliver_in_app(csm_scope(@acme), "One.")
    deliver_in_app(csm_scope(@acme), "Two.")
    deliver_in_app(csm_scope(@globex), "Not yours.")

    post read_all_inbox_path

    assert_equal 0, @acme.inbox_messages.unread.count
    assert_equal 1, @globex.inbox_messages.unread.count
  end

  test "another account's messages are invisible, and not markable" do
    deliver_in_app(csm_scope(@globex), "Globex only — three entries published.")
    theirs = @globex.inbox_messages.sole

    get inbox_path
    assert_select ".msg__text", text: /Globex only/, count: 0
    assert_select ".empty h2", text: "Nothing yet"

    post read_inbox_message_path(theirs)
    assert_response :not_found
    assert_not theirs.reload.read?
  end

  # --- Answering back ---------------------------------------------------------
  # An agent that asks a direct question and leaves the customer nothing but
  # "Mark read" has not had a conversation. Every test below drives the composer
  # the inbox now renders.

  test "the inbox offers a composer on every message" do
    deliver_in_app(csm_scope(@acme), "Want a hand publishing your first entry?")

    get inbox_path

    assert_select "form[action=?] input[name=body]",
                  reply_inbox_message_path(@acme.inbox_messages.sole)
  end

  test "a reply reaches the agent that sent the message, with that message quoted" do
    deliver_in_app(csm_scope(@acme), "Want me to help you get \"Scheduled exports\" out the door?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Let's do it — open Changelog and hit Publish.")

    post reply_inbox_message_path(message), params: { body: "Yes please." }

    assert_redirected_to inbox_path
    # The antecedent: without it a bare "Yes please." reaches a model that has
    # never seen what it is agreeing to.
    asked = Concierge::Test::FakeChat.current.prompts.sole
    assert_includes asked, "Scheduled exports"
    assert_includes asked, "Yes please."
    assert_equal "Let's do it — open Changelog and hit Publish.", message.reload.agent_reply
    assert_equal "Yes please.", message.reply_body
  end

  # THE agent boundary. Bill and Kit have different personas, tool scopes and
  # authority envelopes; a reply routed to the wrong one crosses the seam the
  # whole engine is built around, and does it silently.
  test "a reply to the billing agent reaches billing, and never the CSM" do
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "I've made a note of it.")

    post reply_inbox_message_path(message), params: { body: "Can I update it here?" }

    assert_equal 1, Concierge::AgentRun.for_scope(billing_scope(@acme)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count,
                 "a reply to Bill was answered by Kit"
    assert_includes Concierge::Test::FakeChat.current.system_prompt,
                    "You are Bill, the billing agent for this account."
  end

  test "the request cannot re-route a reply to a different agent" do
    # The agent comes off the ChannelDelivery row this message was delivered
    # under, not off the request — so naming one is not a way across.
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "I've made a note of it.")

    post reply_inbox_message_path(message), params: { body: "Sure.", agent: "csm" }

    assert_equal 1, Concierge::AgentRun.for_scope(billing_scope(@acme)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
  end

  test "replying is reading — the customer does not have to do both" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Happy to.")

    post reply_inbox_message_path(message), params: { body: "Yes." }

    assert message.reload.read?, "an answered question was still flagged unread"
    follow_redirect!
    assert_select ".badge", count: 0
  end

  test "the one-click affirmative sends the affirmative, and only where something was asked" do
    deliver_in_app(csm_scope(@acme), "Want me to help you publish it?")
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.")
    asked, told = @acme.inbox_messages.order(:id).to_a

    get inbox_path
    assert_select "form[action=?] input[value=?]",
                  reply_inbox_message_path(asked), Inbox::AFFIRMATIVE
    assert_select "form[action=?] input[value=?]",
                  reply_inbox_message_path(told), Inbox::AFFIRMATIVE, count: 0

    Concierge::Test::FakeChat.script(reply: "Great — here's how.")
    post reply_inbox_message_path(asked), params: { body: Inbox::AFFIRMATIVE }

    assert_equal Inbox::AFFIRMATIVE, asked.reload.reply_body
  end

  test "the exchange is there on the next request, and the composer is not" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Open Changelog and hit Publish.")

    post reply_inbox_message_path(message), params: { body: "Yes please." }
    follow_redirect!

    assert_select ".bubble--user", text: "Yes please."
    assert_select ".bubble--agent", text: "Open Changelog and hit Publish."
    assert_select "form[action=?] input[name=body]", reply_inbox_message_path(message), count: 0
  end

  test "the exchange links to the engine's own audit row for the turn" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Sure.")

    post reply_inbox_message_path(message), params: { body: "Yes." }

    run = Concierge::AgentRun.for_scope(csm_scope(@acme)).sole
    assert_equal run.id, message.reload.reply_run_id
    assert_equal "reactive", run.trigger
  end

  test "a turn that fails leaves the message unanswered and says so" do
    # The alternative is telling a customer their question landed when the model
    # never answered it, and clearing the flag that would have reminded them.
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "overloaded"))

    post reply_inbox_message_path(message), params: { body: "Yes please." }

    assert_redirected_to inbox_path
    assert_not message.reload.replied?
    assert_not message.read?
    assert_nil message.reply_body
    follow_redirect!
    assert_select ".flash", text: /wasn't sent/
  end

  test "an empty reply is not a turn" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    post reply_inbox_message_path(message), params: { body: "   " }

    assert_empty Concierge::Test::FakeChat.current.prompts
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
    assert_not message.reload.replied?
  end

  test "another account's message cannot be answered" do
    deliver_in_app(csm_scope(@globex), "Globex only.")
    theirs = @globex.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    post reply_inbox_message_path(theirs), params: { body: "Answering on your behalf." }

    assert_response :not_found
    assert_not theirs.reload.replied?
    assert_empty Concierge::Test::FakeChat.current.prompts
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@globex)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
  end

  test "an email delivery is audited but is not an in-app message" do
    Concierge::ChannelDelivery.create!(
      **csm_scope(@acme).key, channel: "email", kind: "outreach",
      sent_at: 1.day.ago, unsubscribe_token: SecureRandom.hex(8)
    )

    get inbox_path

    assert_select ".empty h2", text: "Nothing yet"
  end
end
