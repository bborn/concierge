module Concierge
  module Admin
    # The approval queue (design §10.6/§10.7). Every action an agent proposed but
    # is not allowed to perform itself waits here for a human — an outbound
    # message from a gated agent, a record update, a refund.
    #
    # This screen is one of §10.7's thin adapters: it authenticates the human and
    # calls Concierge::ApprovalIntake. It holds no execution logic, so a Slack
    # button (step 4) and this form take the identical path, with the identical
    # maker-checker refusals.
    class ProposalsController < BaseController
      def index
        @awaiting = Concierge::AgentProposal.awaiting
        @waiting_on_a_human_to_perform =
          Concierge::AgentProposal.unexecuted.select(&:human_execution?)
        @failed   = Concierge::AgentProposal.approved.where.not(execution_failed_at: nil)
        @decided  = Concierge::AgentProposal.where(state: %w[executed rejected expired])
                                            .recent.limit(50)
      end

      def update
        proposal = Concierge::AgentProposal.find(params[:id])

        outcome =
          case params[:transition]
          when "approve"  then Concierge::ApprovalIntake.approve(proposal, by: actor)
          when "reject"   then Concierge::ApprovalIntake.reject(proposal, by: actor, reason: params[:reason])
          when "correct"  then Concierge::ApprovalIntake.correct(proposal, by: actor, payload: corrected_payload)
          when "executed" then Concierge::ApprovalIntake.record_execution(proposal, by: actor)
          when "retry"    then Concierge::ApprovalIntake.retry_execution(proposal, by: actor)
          else
            return redirect_to admin_proposals_path,
                               alert: "unknown transition #{params[:transition].inspect}"
          end

        redirect_to admin_proposals_path, **flash_for(proposal.reload, outcome)
      rescue Concierge::Proposal::GateError => e
        # The refusals are the feature. An operator has to be able to act on one,
        # so it arrives as a message rather than a 500.
        redirect_to admin_proposals_path, alert: e.message
      end

      private

      # An approval whose *execution* was refused is not a success, and must not
      # be reported as one — a precondition that moved, a guard rule that now
      # blocks it, or a disabled agent all leave the row approved and unperformed.
      def flash_for(proposal, outcome)
        case outcome
        when :executed, :rejected, :approved
          { notice: "Proposal ##{proposal.id} #{proposal.state}." }
        else
          { alert: "Proposal ##{proposal.id} was approved but not executed " \
                   "(#{outcome.to_s.tr('_', ' ')})#{": #{proposal.execution_error}" if proposal.execution_error}." }
        end
      end

      # The engine cannot know the host's session shape, so it asks (the same hook
      # the rules screen uses). Without it, maker-checker refuses rather than
      # inventing an approver.
      def actor
        hook = Concierge.config.admin_actor
        (hook ? hook.call(self) : params[:by]).to_s
      end

      # Only the fields the form offers, so a corrected payload cannot grow keys
      # the action class never declared.
      def corrected_payload
        { body: params[:body] }.compact_blank
      end
    end
  end
end
