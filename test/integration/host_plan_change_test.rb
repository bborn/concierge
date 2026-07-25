require "test_helper"

# The authority model, end to end, from the two sides that matter: the customer
# asks, the product says the request is with our team, an AgentProposal waits,
# a human approves it in the admin, and the plan *actually changes*.
class HostPlanChangeTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup { sign_in_as @dana }

  test "asking for a plan change stages a proposal instead of changing the plan" do
    post plan_change_path, params: { plan: "enterprise" }

    assert_redirected_to account_path
    assert_match(/Your request is with our team/, flash[:notice])
    assert_equal "pro", @acme.reload.plan, "the request must not change anything by itself"

    proposal = Concierge::AgentProposal.for_scope(billing_scope(@acme)).sole
    assert_equal "record.plan_change", proposal.action_class
    assert_equal "proposed", proposal.state
    assert_equal "human_approval", proposal.gate, "the :billing envelope is what gated this"
    assert_equal({ from: "pro", to: "enterprise",
                   reason: "requested in-app by dana@acme.test" }, proposal.action_arguments)
    assert_equal "agent:billing", proposal.created_by
  end

  test "the account page shows the request waiting, then the approved outcome" do
    post plan_change_path, params: { plan: "enterprise" }
    get account_path
    assert_select ".card__row", text: /Your request is with our team/

    proposal = Concierge::AgentProposal.for_scope(billing_scope(@acme)).sole
    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    get "/account" # literal: see Concierge::Test::HostApp on crossing back from the engine
    assert_select ".pill--accent", text: "enterprise"
    assert_select ".card__row", text: /Approved\./
    assert_select ".card__row", text: /Your request is with our team/, count: 0
  end

  test "approving in the admin runs the host's executor and the plan really changes" do
    post plan_change_path, params: { plan: "enterprise" }
    proposal = Concierge::AgentProposal.for_scope(billing_scope(@acme)).sole

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    assert_redirected_to "/concierge/admin/proposals"
    assert_equal "executed", proposal.reload.state
    assert_equal "operator@acme.test", proposal.approved_by
    assert_equal "enterprise", @acme.reload.plan
  end

  test "a plan that moved between the request and the approval refuses the execution" do
    post plan_change_path, params: { plan: "enterprise" }
    proposal = Concierge::AgentProposal.for_scope(billing_scope(@acme)).sole

    # Somebody changed the plan by hand in between: the approval was a decision
    # about a different world.
    @acme.update!(plan: "free")

    patch "/concierge/admin/proposals/#{proposal.id}", params: { transition: "approve" }

    assert_equal "approved", proposal.reload.state
    assert_match(/has changed since it was drafted/, proposal.execution_error)
    assert_equal "free", @acme.reload.plan
  end

  test "only one request is in flight at a time" do
    post plan_change_path, params: { plan: "enterprise" }
    post plan_change_path, params: { plan: "free" }

    assert_match(/already have a plan change/, flash[:notice])
    assert_equal 1, Concierge::AgentProposal.for_scope(billing_scope(@acme)).count
  end

  test "the plan you are already on, and a plan we do not sell, are refused" do
    post plan_change_path, params: { plan: "pro" }
    assert_match(/already on pro/, flash[:alert])

    post plan_change_path, params: { plan: "unicorn" }
    assert_match(/isn't a plan we sell/, flash[:alert])

    assert_equal 0, Concierge::AgentProposal.count
  end

  test "one account's request never appears on another account's page" do
    post plan_change_path, params: { plan: "enterprise" }

    sign_in_as @hank
    get account_path

    assert_select ".card__row", text: /Your request is with our team/, count: 0
    assert_equal 0, Concierge::AgentProposal.for_scope(billing_scope(@globex)).count
  end
end
