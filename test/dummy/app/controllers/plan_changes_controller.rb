# The gated path, from the customer's side.
#
# Asking for a plan change does not change the plan. It stages an AgentProposal
# under the :billing agent's authority envelope (`default :human_approval`), so
# the customer is told their request is with our team while a card waits at
# /concierge/admin/proposals. Approving it there runs the host's registered
# `record.plan_change` executor, which is what actually moves the plan — and the
# precondition the host declared re-checks that the world did not move in
# between.
class PlanChangesController < ApplicationController
  def create
    requested = params[:plan].to_s

    return redirect_to(account_path, alert: "That isn't a plan we sell.") unless valid_plan?(requested)
    return redirect_to(account_path, alert: "You're already on #{requested}.") if requested == current_tenant.plan
    return redirect_to(account_path, notice: already_pending_notice) if pending?

    Concierge::Proposal.propose(
      concierge_scope(:billing),
      action_class: "record.plan_change",
      payload: {
        from:   current_tenant.plan,
        to:     requested,
        reason: "requested in-app by #{current_user.email}"
      }
    )

    redirect_to account_path,
                notice: "Your request is with our team. #{billing_name} has put it in front of a human."
  rescue Concierge::Proposal::GateError => e
    # An agent that is :autonomous on this action class has nothing to stage.
    # Saying so beats a queue entry nobody has to read.
    redirect_to account_path, alert: e.message
  end

  private

  def valid_plan?(plan) = Tenant::PLANS.include?(plan)

  def pending?
    Concierge::AgentProposal
      .for_scope(concierge_scope(:billing))
      .of_action_class("record.plan_change")
      .proposed
      .exists?
  end

  def already_pending_notice
    "You already have a plan change with our team — one request at a time."
  end

  def billing_name = billing_persona&.name || "Billing"
end
