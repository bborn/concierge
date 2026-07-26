module Concierge
  # The inbound approval seam (design §10.7). Delivery and approval-intake are two
  # different concerns: +Channel::Base+ is outbound-only ("never raises, deliver +
  # audit"), and the button-click that comes *back* does not belong in it. So
  # surfaces — Slack Block Kit, an Avo screen, the engine's own admin — are thin
  # adapters that authenticate a human and call this:
  #
  #   ApprovalIntake.approve(proposal, by: "sam@acme.test")
  #   ApprovalIntake.reject(proposal,  by: "sam@acme.test", reason: "wrong tone")
  #   ApprovalIntake.correct(proposal, by: "sam@acme.test", payload: { body: "…" })
  #
  # The seam holds the policy and no transport; a surface holds a transport and no
  # policy. Step 4's Slack adapter adds nothing here but a way in.
  #
  # Every refusal is a raise, because a surface that ignored a return value would
  # otherwise report an approval that never happened. The engine's admin screen
  # catches them and shows the operator what to do — the refusals *are* the
  # feature.
  module ApprovalIntake
    class << self
      # The human tap. Enforces maker-checker, transitions the row, and — for a
      # +:human_approval+ gate — invokes Proposal::Execute. A +:human_execution+
      # proposal is only approved here: the human then performs it themselves and
      # records that (#record_execution).
      #
      # Returns the execution status when the engine executed, +:approved+ when
      # the human still has to.
      def approve(proposal, by:, execute: true)
        actor = assert_human!(by, "approve")
        assert_open!(proposal)
        assert_maker_checker!(proposal, actor)

        proposal.update!(state: "approved", approved_by: actor, approved_at: Time.current)
        return :approved unless execute
        return :approved if proposal.human_execution?

        Proposal::Execute.call(proposal, by: actor)
      end

      # A human declined. §2.5: a rejection **requires a reason** — a decision
      # nobody can read the reasoning of is not an audit trail, and it is the one
      # signal the agent's operators have that the draft was wrong.
      def reject(proposal, by:, reason:)
        actor = assert_human!(by, "reject")
        assert_open!(proposal)
        if reason.to_s.strip.empty?
          raise Proposal::GateError,
                "rejecting proposal #{proposal.id} needs a reason — it is the only " \
                "record of why this was not the right action"
        end

        # +rejected_by+ rather than reusing +approved_by+: a column that holds
        # whoever last touched the row would make every audit query ask "…but did
        # they approve or decline it?" And approved_at/rejected_at are mutually
        # exclusive by validation, so this cannot read as both.
        proposal.update!(state: "rejected", rejected_by: actor, rejected_at: Time.current,
                         rejected_reason: reason.to_s.strip)
        :rejected
      end

      # Edit-then-approve (§10.7). The agent's draft was nearly right; the human
      # fixes it and approves the fixed version. The original is kept, because
      # "what did the human have to change" is how you find out the agent is
      # drifting.
      #
      # Correcting re-baselines the precondition: the human just looked at the
      # world and decided, so what they saw is what the execution re-validates
      # against.
      def correct(proposal, by:, payload:, execute: true)
        actor = assert_human!(by, "correct")
        assert_open!(proposal)
        assert_maker_checker!(proposal, actor)

        merged = proposal.payload.merge(payload.to_h.transform_keys(&:to_s))
        proposal.update!(
          payload:             merged,
          original_payload:    proposal.original_payload.presence || proposal.payload,
          corrected_by:        actor,
          corrected_at:        Time.current,
          precondition_digest: rebaselined_digest(proposal, merged)
        )

        approve(proposal, by: actor, execute: execute)
      end

      # A +:human_execution+ action the human went and performed (§10.5). The
      # engine records it; it never carries it out. Requires an approved row —
      # there is no path that records an execution for something nobody approved.
      def record_execution(proposal, by:)
        actor = assert_human!(by, "record an execution for")
        unless proposal.approved?
          raise Proposal::GateError,
                "proposal #{proposal.id} is #{proposal.state}, so there is no approved " \
                "action to record an execution for"
        end

        proposal.update!(state: "executed", executed_by: actor, executed_at: Time.current)
        :executed
      end

      # Clear a recorded execution failure and try again. Deliberately a human
      # act: automatic retries of an action a human approved once is how one
      # refund becomes two, so nothing in the engine re-attempts on its own.
      #
      # +execute: false+ is the same opt-out +approve+ has, and for the same
      # reason (§10.7): a surface with a response budget — a Retry button on a
      # Slack card — cannot promise to outlast a host executor, so it clears the
      # failure here (a row write, and it *is* the record of the human's decision
      # to try again) and hands the doing to Concierge::ProposalExecutionJob. The
      # job needs no +retry_failed:+ of its own, because the failure it would have
      # been refused by is already cleared.
      #
      # Clearing without executing would otherwise leave a row reading "approved,
      # nothing recorded, nothing wrong" — indistinguishable from an approval that
      # was never attempted, with the previous failure erased and nothing in its
      # place. So the queued retry is stamped on the row, where the admin queue and
      # any card that redraws can both see it, and Proposal::Execute clears it
      # again the moment it has a real outcome to report.
      #
      # Returns the execution status when it executed, +:approved+ when it left the
      # doing to someone else — the same two answers +approve+ gives.
      def retry_execution(proposal, by:, execute: true)
        actor = assert_human!(by, "retry")
        proposal.update_columns(execution_error: nil, execution_failed_at: nil,
                                execution_retry_queued_at: (Time.current unless execute),
                                updated_at: Time.current)
        return :approved unless execute

        Proposal::Execute.call(proposal, by: actor, retry_failed: true)
      end

      private

      # An actor is required, and it may not be an agent. Concierge::Rules already
      # reserves the +agent:+ prefix for the engine's own writes, and it means the
      # same thing here: an agent may propose, and can never approve.
      def assert_human!(by, verb)
        actor = by.to_s.strip
        raise Proposal::GateError, "a human actor is required to #{verb} a proposal" if actor.empty?

        if Rules.agent_actor?(actor)
          raise Proposal::GateError,
                "#{actor} is an agent: an agent may propose an action but never #{verb} one"
        end

        actor
      end

      def assert_open!(proposal)
        if proposal.expired?
          raise Proposal::GateError,
                "proposal #{proposal.id} expired on #{proposal.expires_at} — it has to be " \
                "re-proposed against current state rather than approved late"
        end
        return if proposal.proposed?

        raise Proposal::GateError,
              "proposal #{proposal.id} is #{proposal.state}, so there is nothing to decide"
      end

      def assert_maker_checker!(proposal, actor)
        return unless actor == proposal.created_by.to_s.strip

        raise Proposal::GateError,
              "#{actor} proposed #{proposal.action_class} ##{proposal.id} and cannot also " \
              "approve it (maker-checker)"
      end

      def rebaselined_digest(proposal, payload)
        return proposal.precondition_digest if proposal.precondition_digest.blank?

        scope = Proposal.scope_for(proposal)
        return proposal.precondition_digest unless scope

        resolver = Proposal.registry.precondition_for(proposal.action_class)
        return proposal.precondition_digest unless resolver

        Proposal.digest(Proposal.invoke(resolver, scope, payload.deep_symbolize_keys))
      end
    end
  end
end
