module Concierge
  module Channel
    # In-app delivery. It must ACTIVELY surface (open a panel / raise a badge),
    # not just persist a row (design §3.5).
    #
    # The engine does not do the surfacing itself, and deliberately ships no
    # default broadcaster. It keeps a payload *digest* — the delivery ledger is
    # not a message store — so anything that could push these words to a browser
    # would first have to invent a message store, a stream name and a partial,
    # which are three host decisions wearing one hat. `config.in_app_broadcaster`
    # is where the host makes them (the dummy host's InboxMessage + Turbo Stream
    # broadcast is the worked example).
    #
    # What the engine owes in return is honesty about whether that ever happened.
    # A host that lists this channel and configures no broadcaster used to get a
    # silent no-op audited as `:delivered` — the ledger asserting the customer was
    # reached over the one channel that had nowhere to reach them. So the channel
    # declares itself unconfigured without the hook, and the router moves on to
    # email instead.
    class InApp < Base
      def name
        :in_app
      end

      def configured?
        Concierge.config.in_app_broadcaster.present?
      end

      # Always available once configured (inherited) — an in-app message can wait
      # for the user's next visit.

      private

      def perform_delivery(payload)
        Concierge.config.in_app_broadcaster.call(subject, payload)
      end
    end
  end
end
