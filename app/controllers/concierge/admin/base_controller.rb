module Concierge
  module Admin
    # Base for the CRM-style admin. Fails closed: without a configured
    # authenticate_admin hook, access is denied.
    class BaseController < Concierge::ApplicationController
      before_action :authenticate_admin!

      private

      def authenticate_admin!
        hook = Concierge.config.authenticate_admin
        head :forbidden unless hook && hook.call(self)
      end
    end
  end
end
