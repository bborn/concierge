module Concierge
  # One-click unsubscribe endpoint (CAN-SPAM). The token is minted per delivery;
  # visiting the link opts the subject out of all future outreach.
  class UnsubscribesController < ApplicationController
    def show
      delivery = ChannelDelivery.find_by(unsubscribe_token: params[:token])

      if delivery
        pref = OutreachPreference.find_or_initialize_by(
          subject_type: delivery.subject_type,
          subject_id:   delivery.subject_id
        )
        pref.update!(opted_out: true)
        render plain: "You have been unsubscribed. You won't receive further messages."
      else
        render plain: "This unsubscribe link is no longer valid.", status: :not_found
      end
    end
  end
end
