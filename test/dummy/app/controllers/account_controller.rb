# The account page: plan, the two agents that work this account, the gated
# upgrade request, and the handoff control.
class AccountController < ApplicationController
  def show
    @plan_change   = last_plan_change
    @pending_plan_change = @plan_change if @plan_change&.proposed?
    @routines      = Concierge::Routine.for_scope(concierge_scope(:csm)).order(:id)
    @entries_count = current_tenant.changelog_entries.published.count
  end

  private

  # Narrowed to (:billing, this account): a proposal belonging to another account
  # is not reachable from here at all.
  def last_plan_change
    Concierge::AgentProposal
      .for_scope(concierge_scope(:billing))
      .of_action_class("record.plan_change")
      .recent
      .first
  end
end
