require "test_helper"
require "turbo/broadcastable/test_helper"

# In-app delivery "must ACTIVELY surface (open a panel / raise a badge), not just
# persist a row" (design §3.5) — and until now this host only persisted, so the
# one channel whose entire purpose is active surfacing surfaced nothing. A
# message that arrived while the customer had the app open was invisible until
# they happened to reload.
#
# Everything here is the push half: what goes down the account's Turbo Stream,
# and — as much as it matters — what does not go down anyone else's.
class HostInboxLiveTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  setup { sign_in_as @dana }

  # --- Arriving ---------------------------------------------------------------

  test "a message delivered while the page is open is pushed to it" do
    streams = capture_turbo_stream_broadcasts(@acme) do
      deliver_in_app(csm_scope(@acme), "Want a hand publishing your first entry?")
    end

    prepend = streams.find { |s| s["action"] == "prepend" }
    assert_equal "inbox-messages", prepend["target"]
    assert_includes prepend.to_html, "Want a hand publishing your first entry?"
    # Who is talking is the point of the multi-agent split, so the pushed card
    # has to carry it — and the only place that knows is the engine's delivery
    # row, which is why it is now written before the broadcaster runs.
    assert_includes prepend.to_html, "Kit"

    # The empty state is what was on screen a moment ago.
    assert streams.any? { |s| s["action"] == "remove" && s["target"] == "inbox-empty" }
  end

  test "the badge goes up on whatever page the customer is actually on" do
    streams = capture_turbo_stream_broadcasts(@acme) do
      deliver_in_app(csm_scope(@acme), "Something worth a look.")
    end

    badge = streams.find { |s| s["target"] == "inbox-badge" }
    assert_equal "replace", badge["action"]
    assert_includes badge.to_html, ">1<"
  end

  test "a message for one account is never pushed to another" do
    assert_no_turbo_stream_broadcasts(@globex) do
      deliver_in_app(csm_scope(@acme), "Acme only.")
    end
  end

  # The stream name is Turbo-signed, so the only way onto an account's stream is
  # to have been served a page that rendered its signature. Dana's is; Hank's is
  # not, and no request parameter is consulted either way.
  test "the page subscribes this account's browser to this account's stream, and no other" do
    get inbox_path

    assert_select "turbo-cable-stream-source[signed-stream-name=?]",
                  Turbo::StreamsChannel.signed_stream_name(@acme)
    assert_select "turbo-cable-stream-source[signed-stream-name=?]",
                  Turbo::StreamsChannel.signed_stream_name(@globex), count: 0
  end

  test "a delivery the engine could not record is not pushed as if it had been" do
    # No broadcaster, no in-app channel: the router falls through to email rather
    # than auditing a delivery that reached nobody.
    Concierge.configure { |c| c.in_app_broadcaster = nil }

    assert_no_turbo_stream_broadcasts(@acme) do
      deliver_in_app(csm_scope(@acme), "Nowhere to put this.")
    end
    assert_equal 0, @acme.inbox_messages.count
  end

  # --- Answering --------------------------------------------------------------

  test "the answer arrives on the card without a page load" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Open Changelog and hit Publish.")

    post reply_inbox_message_path(message), params: { body: "Yes please." }

    streams = capture_turbo_stream_broadcasts(@acme) do
      perform_enqueued_jobs(only: InboxReplyJob)
    end

    card = streams.find { |s| s["target"] == "inbox_message_#{message.id}" }
    assert_equal "replace", card["action"]
    assert_includes card.to_html, "Open Changelog and hit Publish."
    assert_not_includes card.to_html, "Kit is replying"
  end

  test "the pending card is pushed too, so a second tab sees the reply land" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Sure.")

    streams = capture_turbo_stream_broadcasts(@acme) do
      post reply_inbox_message_path(message), params: { body: "Yes please." }
    end

    card = streams.find { |s| s["target"] == "inbox_message_#{message.id}" }
    assert_includes card.to_html, "Yes please."
    assert_includes card.to_html, "Kit is replying"
  end

  test "a turn that fails pushes the failure, because no flash is left to carry it" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "overloaded"))

    post reply_inbox_message_path(message), params: { body: "Yes please." }

    streams = capture_turbo_stream_broadcasts(@acme) do
      perform_enqueued_jobs(only: InboxReplyJob)
    end

    card = streams.find { |s| s["target"] == "inbox_message_#{message.id}" }
    assert_includes card.to_html, "Your message wasn't sent."
    # ...and the badge that start_reply! cleared comes back up with it.
    badge = streams.find { |s| s["target"] == "inbox-badge" }
    assert_includes badge.to_html, ">1<"
  end

  test "marking a message read clears the badge on every other open page" do
    deliver_in_app(csm_scope(@acme), "One thing worth a look.")
    message = @acme.inbox_messages.sole

    streams = capture_turbo_stream_broadcasts(@acme) do
      post read_inbox_message_path(message)
    end

    badge = streams.find { |s| s["target"] == "inbox-badge" }
    assert_equal "<span id=\"inbox-badge\"></span>", badge.at_css("template").inner_html.strip
  end
end
