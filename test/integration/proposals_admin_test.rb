require "test_helper"

# The approval queue as a screen (design §10.6/§10.7). This screen is a *thin
# adapter*: it authenticates the human and calls Concierge::ApprovalIntake. What
# matters here is that it holds no policy of its own — the same refusals arrive
# through the browser as through a console — and that a refused execution is not
# reported as a success.
class ProposalsAdminTest < ActionDispatch::IntegrationTest
  setup do
    Concierge::Test.configure_agents!
    Concierge.config.authenticate_admin = ->(_c) { true }
    Concierge.config.admin_actor        = ->(_c) { "sam@acme.test" }

    @tenant = Tenant.create!(name: "Acme", plan: "pro")
    @tenant.users.create!(email: "dana@acme.test")
    @subject = Concierge.config.account.build(@tenant)
    @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
  end

  test "the proposals screen fails closed like every other admin screen" do
    Concierge.config.authenticate_admin = nil
    get "/concierge/admin/proposals"
    assert_response :forbidden
  end

  test "a card shows the action, the gate, the payload and who proposed it" do
    staged_message

    get "/concierge/admin/proposals"

    assert_response :success
    assert_includes response.body, "message.outreach"
    assert_includes response.body, "your card expires soon"
    assert_includes response.body, "agent:billing"
    assert_includes response.body, "human approval"
    assert_includes response.body, "Approve"
  end

  # The approver is being asked to trust a draft. Telling them the agent
  # "applied" rule #7 invites them to read the draft as pre-checked; a model can
  # cite a rule while contradicting it (§10.4), so the card says whose claim it is.
  test "a card marks the cited rules as the agent's unverified claim" do
    Concierge::Outreach.deliver(
      Concierge::Result.new(reply_text: "your card expires soon", rule_ids_applied: [ 7 ]),
      @billing, channel: :in_app
    )

    get "/concierge/admin/proposals"

    assert_response :success
    assert_includes response.body, "Rules claimed"
    assert_includes response.body, "not proof it followed them"
    refute_includes response.body, "<dt>Rules applied</dt>"
  end

  test "an operator approves a message and the engine sends it" do
    proposal = staged_message

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    assert_redirected_to "/concierge/admin/proposals"
    assert_equal "sam@acme.test", proposal.reload.approved_by
    assert proposal.executed?
    assert_equal 1, Concierge::ChannelDelivery.count
  end

  test "an operator corrects the draft before approving it" do
    proposal = staged_message

    patch "/concierge/admin/proposals/#{proposal.id}",
          params: { transition: "correct", body: "Your card expires before the 1st." }

    assert_equal "Your card expires before the 1st.", proposal.reload.body
    assert_equal "your card expires soon", proposal.original_payload["body"]
    assert_includes Concierge::InAppInbox.messages.map { |m| m[:body] },
                    "Your card expires before the 1st."
  end

  test "rejecting without a reason is refused, with something an operator can act on" do
    proposal = staged_message

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "reject", reason: "" }

    assert_redirected_to "/concierge/admin/proposals"
    assert_match(/needs a reason/, flash[:alert])
    assert proposal.reload.proposed?
  end

  test "rejecting with a reason records it" do
    proposal = staged_message

    patch "/concierge/admin/proposals/#{proposal.id}",
          params: { transition: "reject", reason: "we emailed them this morning" }

    assert proposal.reload.rejected?
    assert_equal "we emailed them this morning", proposal.rejected_reason
    assert_equal 0, Concierge::ChannelDelivery.count
  end

  test "without an admin_actor hook the gate refuses rather than inventing an approver" do
    Concierge.config.admin_actor = nil
    proposal = staged_message

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    assert proposal.reload.proposed?
    assert_match(/human actor is required/, flash[:alert])
  end

  test "an approval whose execution was refused is not reported as a success" do
    # The failure mode this guards: the flash says "approved" while the customer
    # never got the message and nobody looks again.
    proposal = staged_message
    Concierge::OutreachPreference.for(@subject).update!(opted_out: true)

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    assert_nil flash[:notice]
    assert_match(/approved but not executed/, flash[:alert])
    assert_match(/precondition failed/, flash[:alert])
    assert_equal 0, Concierge::ChannelDelivery.count
  end

  test "an approved proposal the engine refused stays visible, with why and a retry" do
    # Found by driving the running app: an approved :human_approval proposal whose
    # *execution* was refused is decided but unperformed. Listing only
    # :human_execution rows and only hard failures left it in no section at all —
    # invisible is the worst state for this screen to leave anything in.
    proposal = staged_message
    Concierge::OutreachPreference.for(@subject).update!(opted_out: true)
    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }
    assert proposal.reload.approved?
    refute proposal.executed?

    get "/concierge/admin/proposals"

    assert_includes response.body, "##{proposal.id}"
    assert_includes response.body, "has changed since it was drafted"
    assert_includes response.body, "Retry execution"
  end

  test "a money proposal is approved on the screen and executed by the human" do
    proposal = Concierge::Proposal.propose(@billing, action_class: "money.refund",
                                                     payload: { order_id: 42, amount_cents: 2500 })

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }
    assert proposal.reload.approved?
    refute proposal.executed?, "the engine must not move money"

    get "/concierge/admin/proposals"
    assert_includes response.body, "I performed this"

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "executed" }
    assert proposal.reload.executed?
    assert_equal "sam@acme.test", proposal.executed_by
  end

  test "an operator retries an execution that failed, after looking at why" do
    Concierge.configure do |c|
      c.proposals { execute("record.update") { |_p, _s| raise "the CRM was down" } }
    end
    proposal = Concierge::Proposal.propose(@billing, action_class: "record.update",
                                                     payload: { field: "plan" })
    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    get "/concierge/admin/proposals"
    assert_includes response.body, "the CRM was down"
    assert_includes response.body, "Retry"

    Concierge.configure { |c| c.proposals { execute("record.update") { |_p, _s| true } } }
    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "retry" }

    assert proposal.reload.executed?
  end

  test "an unknown transition is refused rather than guessed at" do
    proposal = staged_message

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "yolo" }

    assert_match(/unknown transition/, flash[:alert])
    assert proposal.reload.proposed?
  end

  private

  def staged_message
    Concierge::Outreach.deliver(
      Concierge::Result.new(reply_text: "your card expires soon"), @billing, channel: :in_app
    )
    Concierge::AgentProposal.sole
  end
end
