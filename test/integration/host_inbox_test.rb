require "test_helper"

# Proactive outreach the customer never saw is outreach that did not happen, as
# far as the customer is concerned. The inbox is driven off the engine's own
# ChannelDelivery rows, one `for_scope` query per (agent, this account).
class HostInboxTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp
  include ActiveJob::TestHelper
  include Concierge::Test::BrokenQueue

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

    reply_to(message, "Yes please.")

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

    reply_to(message, "Can I update it here?")

    assert_equal 1, Concierge::AgentRun.for_scope(billing_scope(@acme)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count,
                 "a reply to Bill was answered by Kit"
    assert_includes Concierge::Test::FakeChat.current.system_prompt,
                    "You are Bill, the billing agent for this account."
  end

  test "the request cannot re-route a reply to a different agent" do
    # The agent comes off the ChannelDelivery row this message was delivered
    # under, not off the request — so naming one is not a way across. The job
    # re-resolves it the same way, from the row rather than from its arguments.
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "I've made a note of it.")

    reply_to(message, "Sure.", params: { agent: "csm" })

    assert_equal 1, Concierge::AgentRun.for_scope(billing_scope(@acme)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
  end

  test "replying is reading — the customer does not have to do both" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Happy to.")

    reply_to(message, "Yes.")

    assert message.reload.read?, "an answered question was still flagged unread"
    follow_redirect!
    assert_select ".badge", count: 0
  end

  # --- What buttons a message carries -----------------------------------------
  # Declared by the host, picked by the agent, resolved by the engine — never
  # guessed at from the words (docs/design/message-actions.md). The question-mark
  # heuristic these replace could not tell Bill's statement of fact from a
  # message with nothing to offer.

  test "a statement that asks nothing still carries the button it needs" do
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.",
                   actions: %i[update_payment_method])

    get inbox_path

    assert_select "a[href=?]", "/account#payment", text: "Update payment method"
  end

  test "each agent's message carries its own agent's offers and no others" do
    deliver_in_app(csm_scope(@acme), "Want me to help you publish it?", actions: %i[yes_please])
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.",
                   actions: %i[update_payment_method])
    asked, told = @acme.inbox_messages.order(:id).to_a

    get inbox_path

    assert_select "form[action=?] input[value=?]",
                  reply_inbox_message_path(asked), "Yes, help me with that."
    assert_select "form[action=?] input[value=?]",
                  reply_inbox_message_path(told), "Yes, help me with that.", count: 0
    assert_select "a[href=?]", "/account#payment", count: 1
  end

  test "a reply-shaped offer sends the text the host declared for it" do
    deliver_in_app(csm_scope(@acme), "Want me to help you publish it?", actions: %i[yes_please])
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Great — here's how.")

    reply_to(message, "Yes, help me with that.")

    assert_equal "Yes, help me with that.", message.reload.reply_body
  end

  test "a message whose agent picked nothing still gets a composer" do
    # The composer was never the thing in question: a customer can always answer
    # in words, whatever buttons the message does or does not carry.
    deliver_in_app(billing_scope(@acme), "Your invoice for March is attached.")

    get inbox_path

    assert_select "form[action=?] input[name=body]",
                  reply_inbox_message_path(@acme.inbox_messages.sole)
    assert_select ".msg__reply a.btn", count: 0
  end

  # The end-to-end shape of the decision: the agent names a key on the line its
  # reply ends with, the engine resolves it against what this host declared, and
  # the host renders its own label and its own href.
  test "an agent's own turn decides the buttons its message carries" do
    Concierge::Test::FakeChat.script(
      reply: "You've got \"Scheduled exports\" sitting in drafts.\n\nActions-Offered: open_drafts"
    )
    scope  = csm_scope(@acme)
    result = Concierge::Run.proactive(scope, instruction: "Nudge them about the draft.")

    assert_equal :delivered, Concierge::Outreach.deliver(result, scope, channel: :in_app)

    get inbox_path
    assert_select "a[href=?]", "/changelog", text: "Open your drafts"
    # ...and the machine-readable line is nowhere near the customer.
    assert_select ".msg__text", text: /Actions-Offered/, count: 0
  end

  test "a key the host never declared renders no button" do
    # The model's reach exceeding the vocabulary costs a missing button, never a
    # fabricated one — there is no path from model output to a label or an href.
    Concierge::Test::FakeChat.script(reply: "One thing.\n\nActions-Offered: cancel_their_account")
    scope  = csm_scope(@acme)
    result = Concierge::Run.proactive(scope, instruction: "Check in.")

    Concierge::Outreach.deliver(result, scope, channel: :in_app)

    get inbox_path
    assert_select ".msg__reply a.btn", count: 0
    assert_select ".msg__text", text: /One thing./
  end

  test "the buttons a message was delivered with survive a change of config" do
    # What a message offered when it was sent is history. Re-deriving it at render
    # time would let a config edit silently rewrite messages already delivered.
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.",
                   actions: %i[update_payment_method])
    Concierge.config.agent(:billing).actions.clear

    get inbox_path

    assert_select "a[href=?]", "/account#payment", text: "Update payment method"
  end

  test "the exchange is there on the next request, and the composer is not" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Open Changelog and hit Publish.")

    reply_to(message, "Yes please.")
    get inbox_path

    assert_select ".bubble--user", text: "Yes please."
    assert_select ".bubble--agent", text: "Open Changelog and hit Publish."
    assert_select "form[action=?] input[name=body]", reply_inbox_message_path(message), count: 0
  end

  test "the exchange links to the engine's own audit row for the turn" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Sure.")

    reply_to(message, "Yes.")

    run = Concierge::AgentRun.for_scope(csm_scope(@acme)).sole
    assert_equal run.id, message.reload.reply_run_id
    assert_equal "reactive", run.trigger
  end

  test "an empty reply is not a turn" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    assert_no_enqueued_jobs only: InboxReplyJob do
      post reply_inbox_message_path(message), params: { body: "   " }
    end

    assert_empty Concierge::Test::FakeChat.current.prompts
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
    assert_not message.reload.replied?
    assert_nil message.reply_body
  end

  test "another account's message cannot be answered" do
    deliver_in_app(csm_scope(@globex), "Globex only.")
    theirs = @globex.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    assert_no_enqueued_jobs only: InboxReplyJob do
      post reply_inbox_message_path(theirs), params: { body: "Answering on your behalf." }
    end

    assert_response :not_found
    assert_not theirs.reload.replied?
    assert_empty Concierge::Test::FakeChat.current.prompts
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@globex)).count
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@acme)).count
  end

  # --- The turn is not the request --------------------------------------------
  # Offline, `Dummy::ScriptedChat` answers in microseconds and none of this shows.
  # Against a real provider the old path was a customer watching a form post spin
  # for the length of a model turn.

  test "the reply comes back before the turn does, with their words already on the card" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "should not have run yet")

    assert_enqueued_jobs 1, only: InboxReplyJob do
      post reply_inbox_message_path(message), params: { body: "Yes please." }
    end

    assert_redirected_to inbox_path
    assert_empty Concierge::Test::FakeChat.current.prompts,
                 "the turn ran inside the request the customer was waiting on"

    # Pending is a persisted state, not a spinner the browser drew — so it is
    # still here on a reload, in another tab, and on the phone in their pocket.
    assert message.reload.awaiting_reply?
    get inbox_path
    assert_select ".bubble--user", text: "Yes please."
    assert_select ".bubble--thinking", text: /Kit is replying/
    assert_select "form[action=?] input[name=body]", reply_inbox_message_path(message), count: 0
  end

  test "a message already being answered is not answered twice" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.script(reply: "Open Changelog and hit Publish.")

    reply_to(message, "Yes please.")

    # The composer is gone from the card, so this is a hand-crafted POST — and it
    # must not overwrite an exchange that already happened.
    post reply_inbox_message_path(message), params: { body: "Actually, no." }

    assert_equal "Yes please.", message.reload.reply_body
    assert_equal "Open Changelog and hit Publish.", message.agent_reply
    follow_redirect!
    assert_select ".flash", text: /already answered/
  end

  test "a turn that fails leaves the message unanswered, unread, and says so on the card" do
    # The alternative is telling a customer their question landed when the model
    # never answered it, and clearing the flag that would have reminded them.
    # A flash cannot carry this any more: the request that started the turn was
    # answered long before it failed, so the card has to say it instead.
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "overloaded"))

    reply_to(message, "Yes please.")

    assert_not message.reload.replied?
    assert_not message.read?, "a question nobody answered stopped asking for attention"
    assert message.reply_failed?

    get inbox_path
    assert_select ".bubble--error", text: /wasn't sent/
    assert_select ".badge", text: "1"
    # Their words are kept, so trying again is a click and not re-typing.
    assert_select "form[action=?] input[value=?]",
                  reply_inbox_message_path(message), "Yes please."
  end

  test "a failed reply can be sent again" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole
    Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "overloaded"))
    reply_to(message, "Yes please.")

    Concierge::Test::FakeChat.script(reply: "Of course — here's how.")
    reply_to(message, "Yes please.")

    assert message.reload.replied?
    assert_not message.reply_failed?
    assert_equal "Of course — here's how.", message.agent_reply
  end

  test "a queue that will not take the work says so rather than leaving a card spinning" do
    deliver_in_app(csm_scope(@acme), "Want a hand with the draft?")
    message = @acme.inbox_messages.sole

    with_broken_queue(InboxReplyJob) do
      post reply_inbox_message_path(message), params: { body: "Yes please." }
    end

    assert_not message.reload.awaiting_reply?, "a card was left waiting on a job that does not exist"
    assert message.reply_failed?
    follow_redirect!
    assert_select ".flash", text: /wasn't sent/
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
