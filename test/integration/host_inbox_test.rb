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

  test "an email delivery is audited but is not an in-app message" do
    Concierge::ChannelDelivery.create!(
      **csm_scope(@acme).key, channel: "email", kind: "outreach",
      sent_at: 1.day.ago, unsubscribe_token: SecureRandom.hex(8)
    )

    get inbox_path

    assert_select ".empty h2", text: "Nothing yet"
  end
end
