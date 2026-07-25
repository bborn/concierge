# "Talk to a human." Opens a Concierge::Handoff on the CSM thread; while it is
# active the agent's autonomous proactive sends are suppressed by the engine and
# the product says so, rather than leaving the customer to guess whether anyone
# is there. Closing it hands control back.
#
# The takeover is per (agent, account): taking the CSM thread does not silence
# the billing agent, which is why this names :csm explicitly.
class HandoffsController < ApplicationController
  OPERATOR = "support@acme.test".freeze

  def create
    Concierge::Handoff.seize!(concierge_scope(:csm), operator: OPERATOR)
    redirect_back fallback_location: account_path,
                  notice: "A person from our team has this conversation. #{kit} has stepped back."
  end

  def destroy
    Concierge::Handoff.active_for(concierge_scope(:csm))&.release!
    redirect_back fallback_location: account_path,
                  notice: "#{kit} has the thread again."
  end

  private

  def kit = csm_persona&.name || "Your agent"
end
