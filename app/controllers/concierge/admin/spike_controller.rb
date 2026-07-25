module Concierge
  module Admin
    # THROWAWAY SPIKE SCREEN — phase 10, step 0 (design §10.10).
    #
    # The gate's evidence, on one page: every declared agent with its six slots,
    # the memory namespaces those agents actually own, and the per-run provenance
    # of a proactive run for each. 404s unless the spike flag is on, so it does
    # not exist for a normal host. Deleted by step 1.
    class SpikeController < BaseController
      before_action :require_spike!

      def index
        @agents     = Concierge.config.agents
        @subjects   = Concierge.config.account.each_subject.to_a
        @namespaces = Concierge::Memory.active.group(:subject_type).count
        @provenance = Concierge::Spike::Provenance.recent(limit: 25)
      end

      # Run every enabled agent proactively against one subject, so the two
      # prompts and the two provenance rows can be compared side by side.
      def run
        subject = Concierge.config.account.find_subject(params[:subject_id])

        Concierge::Spike.scopes_for(subject).each do |scope|
          Concierge::Spike::Run.proactive(
            scope,
            instruction: "Weekly check-in: anything about this account worth raising?"
          )
        end

        redirect_to admin_spike_path
      end

      private

      def require_spike!
        head :not_found unless Concierge::Spike.enabled?
      end
    end
  end
end
