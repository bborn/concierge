module Concierge
  module Admin
    # Per-run provenance (design §10.4): for each turn, what the agent was
    # actually told. The memories injected, the rules injected *at the versions
    # they were then*, the snapshot digest it reasoned over, and which rules it
    # claimed to apply.
    #
    # This is the screen that answers "prove which policy was in force when the
    # agent said what it said" — and it flags the inverse too: a run that cited a
    # rule which was never in its prompt.
    class RunsController < BaseController
      def index
        @runs = Concierge::AgentRun.recent.limit(100)
      end
    end
  end
end
