require "test_helper"

# Where Bill's "Update payment method" offer lands, and what happens when the
# customer follows it. The point of the offer is that it goes somewhere real: a
# button off a message about an expiring card that opened a page with no card on
# it would be a demo of a button, not of the seam.
#
# Note what is *not* here: no proposal, no authority envelope, no agent. An offer
# is an invitation to a host surface — the customer changing their own card is
# the host's write, and always was. The things an agent performs go through
# AgentProposal (see HostPlanChangeTest).
class HostPaymentMethodTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup do
    @acme.update!(card_last4: "4242", card_expires_on: 6.weeks.from_now.end_of_month)
    sign_in_as @dana
  end

  test "the offer's href is a page on this host, with the card on it" do
    deliver_in_app(billing_scope(@acme), "The card on file expires in March.",
                   actions: %i[update_payment_method])

    get inbox_path
    href = css_select("a.btn").find { |a| a.text.include?("Update payment method") }["href"]

    get href
    assert_response :success
    assert_select "#payment", text: /Card ending 4242/
    assert_select "#payment .pill--warn", text: "expiring"
  end

  test "replacing the card is the customer's own write" do
    patch payment_method_path, params: { card_last4: "1881", card_expires_on: "2031-08" }

    assert_redirected_to account_path(anchor: "payment")
    assert_equal "1881", @acme.reload.card_last4
    assert_equal Date.new(2031, 8, 31), @acme.card_expires_on,
                 "a card is good through the end of the month it expires in"
    assert_equal 0, Concierge::AgentProposal.count, "nothing here is the agent's to approve"
  end

  test "a half-filled form changes nothing and says so" do
    patch payment_method_path, params: { card_last4: "18", card_expires_on: "" }

    assert_redirected_to account_path(anchor: "payment")
    assert_equal "4242", @acme.reload.card_last4
    follow_redirect!
    assert_select ".flash", text: /last 4 digits/
  end

  test "the expiring badge clears once the card is replaced" do
    patch payment_method_path, params: { card_last4: "1881", card_expires_on: "2031-08" }

    get account_path
    assert_select "#payment .pill--warn", count: 0
    assert_select "#payment", text: /Nothing to do/
  end

  test "another account's card is not reachable from here" do
    patch payment_method_path, params: { card_last4: "9999", card_expires_on: "2031-08" }

    assert_nil @globex.reload.card_last4
  end
end
