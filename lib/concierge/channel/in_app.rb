module Concierge
  module Channel
    # In-app delivery. It must ACTIVELY surface (open a panel / raise a badge),
    # not just persist a row (design §3.5). Surfacing is a Turbo broadcast; the
    # broadcast target is host-configurable and the call is guarded so tests (and
    # apps without ActionCable) don't need a live cable.
    class InApp < Base
      def name
        :in_app
      end

      # Always available — an in-app message can wait for the user's next visit.
      def available_for?(_subject)
        true
      end

      private

      def perform_delivery(payload)
        surface(payload)
      end

      def surface(payload)
        broadcaster = Concierge.config.in_app_broadcaster
        broadcaster&.call(subject, payload)
      end
    end
  end
end
