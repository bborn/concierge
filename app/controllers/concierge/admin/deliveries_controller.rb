module Concierge
  module Admin
    # Read-only audit log of everything the agent sent.
    class DeliveriesController < BaseController
      def index
        @deliveries = Concierge::ChannelDelivery.order(sent_at: :desc).limit(200)
      end
    end
  end
end
