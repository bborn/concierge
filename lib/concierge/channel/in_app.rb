module Concierge
  module Channel
    # In-app delivery. It must ACTIVELY surface (open a panel / raise a badge),
    # not just persist a row (design §3.5). Surfacing is a Turbo broadcast; the
    # broadcast target is host-configurable and the call is guarded so tests (and
    # apps without ActionCable) don't need a live cable.
    class InApp < Base
      # Always available (inherited) — an in-app message can wait for the user's
      # next visit.
      def name
        :in_app
      end

      private

      def perform_delivery(payload)
        Concierge.config.in_app_broadcaster&.call(subject, payload)
      end
    end
  end
end
