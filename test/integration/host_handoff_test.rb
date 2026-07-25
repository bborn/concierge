require "test_helper"

# "Talk to a human." Control is takeover, not gating: the agent stops reaching
# out, the product says so, and closing the handoff hands control back. The
# takeover is per (agent, account), so it must not silence billing.
class HostHandoffTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup { sign_in_as @dana }

  test "asking for a human opens a handoff on the CSM thread" do
    post handoff_path

    assert_redirected_to account_path
    handoff = Concierge::Handoff.active_for(csm_scope(@acme))
    assert handoff
    assert_equal "support@acme.test", handoff.operator
    assert_nil Concierge::Handoff.active_for(billing_scope(@acme)),
               "taking the CSM thread must not silence billing"
  end

  test "the product says the agent has stepped back" do
    post handoff_path
    get account_path

    assert_select ".pill--warn", text: "stepped back"
    assert_select ".card__row", text: /has taken this conversation over/
    assert_select ".kit__notice", text: /A person has this thread/
  end

  test "closing the handoff gives the thread back" do
    post handoff_path
    delete handoff_path

    assert_nil Concierge::Handoff.active_for(csm_scope(@acme))

    get account_path
    assert_select ".pill--good", text: "on"
    assert_select "[data-kit-form]"
  end

  test "a handoff on one account leaves another account's agent alone" do
    post handoff_path

    assert_nil Concierge::Handoff.active_for(csm_scope(@globex))

    sign_in_as @hank
    get account_path
    assert_select ".pill--good", text: "on"
  end
end
