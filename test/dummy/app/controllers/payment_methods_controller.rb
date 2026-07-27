# Where "Update payment method" lands.
#
# Bill's outreach is about a card that expires in March, and a button off that
# message that opened a page with nothing to change would be a demo of a button.
# This is a real (if tiny) product surface: the card on file lives on the host's
# own Tenant, and replacing it is the host's own write.
#
# Deliberately nothing to do with Concierge. The engine carried a key the host
# declared and the host rendered a link to its own route; no agent, no authority
# envelope, no proposal is involved in the customer changing their own card. An
# offer is an invitation to a host surface, not an action the agent performs —
# the things agents perform go through AgentProposal (see PlanChangesController
# for one that does).
class PaymentMethodsController < ApplicationController
  def update
    last4   = params[:card_last4].to_s.gsub(/\D/, "").last(4)
    expires = parse_expiry(params[:card_expires_on])

    if last4.length < 4 || expires.nil?
      return redirect_to account_path(anchor: "payment"),
                         alert: "Give us the last 4 digits and an expiry date."
    end

    current_tenant.update!(card_last4: last4, card_expires_on: expires)
    redirect_to account_path(anchor: "payment"), notice: "Payment method updated."
  end

  private

  # An <input type="month"> posts "YYYY-MM". Store the last day of that month,
  # because a card is good through the end of the month it expires in.
  def parse_expiry(value)
    Date.strptime(value.to_s, "%Y-%m").end_of_month
  rescue Date::Error
    nil
  end
end
