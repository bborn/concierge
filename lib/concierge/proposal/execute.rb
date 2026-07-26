module Concierge
  class Proposal
    # Perform an approved proposal (design §10.6). The engine's authority ends
    # here: this class establishes that an action is *allowed to reach an
    # executor*, and the executor — the engine's own for +message.*+, the host's
    # for everything else — re-checks its own invariants independently (§10.8).
    #
    # Six refusals stand between an approved row and the executor, in this order:
    #
    #   1. **Execute only from an approved record.** A proposed, rejected, expired
    #      or already-executed row is not performed. There is no argument that
    #      bypasses the row's state.
    #   2. **Expiry.** A stale approval is not a current one.
    #   3. **The kill switch** (§10.1, slot 6). Read again *here*, not only at run
    #      start, so halting a business function also stops its already-approved
    #      work — which is the whole point of an ops halt.
    #   4. **:human_execution never executes in the engine.** Money is the case:
    #      a human approves *and* performs it, and the engine only records that
    #      (ApprovalIntake.record_execution).
    #   5. **Precondition re-validation.** The world may have moved between
    #      propose and approve. A digest mismatch fails the execution rather than
    #      acting on stale assumptions.
    #   6. **Guard rules** (§10.2). An +enforcement: "guard"+ rule's predicate is
    #      re-checked against the payload here, so a policy activated *after* the
    #      draft was written still binds it.
    #
    # Returns a status symbol; it never raises out to the caller, because the one
    # thing worse than a refused execution is a 500 in the middle of one.
    class Execute
      STATUSES = %i[executed already_executed not_approved expired agent_disabled
                    human_execution_required precondition_failed blocked_by_rule
                    execution_previously_failed no_executor unresolved_scope failed].freeze

      def self.call(proposal, by: nil, retry_failed: false)
        new(proposal, by: by, retry_failed: retry_failed).call
      end

      def initialize(proposal, by: nil, retry_failed: false)
        @proposal     = proposal
        @by           = by
        @retry_failed = retry_failed
      end

      def call
        outcome = decide
        # An execution someone queued — a first one handed to
        # ProposalExecutionJob, or a retry from ApprovalIntake.retry_execution
        # with +execute: false+ — is over the moment this class has an answer,
        # including the refusals it does not write to the row, like a missing
        # executor or a halted agent. Leaving the stamp on one of those would have
        # the admin queue promising, forever, that something is about to happen.
        clear_queued_execution if proposal.execution_queued?
        outcome
      end

      private

      attr_reader :proposal

      def decide
        refusal = refusal_reason
        return refusal if refusal

        # Claim the row before doing the work, with a conditional UPDATE that only
        # one caller can win. Marking it executed *first* means a process that
        # dies mid-execution leaves a row that over-reports — and for the action
        # class this exists to protect (a refund), at-most-once is the right
        # failure mode to prefer over at-least-once.
        return :already_executed unless claim!

        dispatch
      end

      def clear_queued_execution
        proposal.update_columns(execution_queued_at: nil, updated_at: Time.current)
      end

      def refusal_reason
        return :already_executed if proposal.executed?
        return :not_approved     unless proposal.approved?
        return :expired          if proposal.expired?
        return :execution_previously_failed if proposal.execution_failed? && !@retry_failed
        return :human_execution_required    if proposal.human_execution?
        return :unresolved_scope unless scope
        return :agent_disabled   unless scope.agent.enabled?
        return :no_executor      unless executor

        precondition_or_guard_refusal
      end

      def precondition_or_guard_refusal
        return record_refusal(:precondition_failed, precondition_mismatch) if precondition_mismatch
        return record_refusal(:blocked_by_rule, guard_refusal) if guard_refusal

        nil
      end

      # The engine digested what the proposal assumed at propose time; this
      # re-digests it now. An action class that declared no precondition has
      # nothing to compare, and this says so rather than reporting a check it
      # never made.
      def precondition_mismatch
        return @precondition_mismatch if defined?(@precondition_mismatch)

        @precondition_mismatch = begin
          expected = proposal.precondition_digest
          current  = Proposal.current_precondition_digest(proposal, scope: scope)

          if expected.blank? || current.blank? || expected == current
            nil
          else
            "the state this proposal assumed has changed since it was drafted " \
            "(#{expected} -> #{current})"
          end
        end
      end

      def guard_refusal
        return @guard_refusal if defined?(@guard_refusal)

        violated = Rules.guard_violations(scope, action_class: proposal.action_class,
                                                 payload: proposal.action_arguments)
        @guard_refusal =
          if violated.empty?
            nil
          else
            "blocked by guard rule(s) #{violated.map(&:id).join(', ')}"
          end
      end

      def claim!
        now = Time.current
        AgentProposal
          .where(id: proposal.id, state: "approved", execution_failed_at: nil)
          .update_all(state: "executed", executed_at: now, executed_by: executed_by,
                      execution_error: nil, execution_queued_at: nil, updated_at: now)
          .positive?
          .tap { proposal.reload }
      end

      # A :human_approval proposal is performed *by the engine*, so the human
      # named here is the one who authorized it, not the one who typed the
      # command. Recording the approver keeps "who is answerable for this" on the
      # row even for actions no person carried out by hand.
      def executed_by
        (@by || proposal.approved_by).to_s.presence
      end

      def dispatch
        result = Proposal.invoke_executor(executor, proposal, scope)
        return :executed unless result == false || result.nil?

        record_failure("the executor for #{proposal.action_class} declined to perform it")
      rescue StandardError => e
        # A host executor that raises must not take the caller down with it, and
        # must not leave the row claiming it succeeded.
        record_failure("#{e.class}: #{e.message}")
      end

      # A failed execution un-claims the row and records why. It is deliberately
      # NOT retried automatically: at-least-once retries of an action a human
      # approved once is how one refund becomes two. A person clears the failure
      # (ApprovalIntake.retry_execution) after looking at it.
      def record_failure(message)
        Concierge.logger&.error(
          "[concierge] proposal #{proposal.id} (#{proposal.action_class}) execution failed: #{message}"
        )
        proposal.update_columns(
          state: "approved", executed_at: nil, executed_by: nil,
          execution_error: message, execution_failed_at: Time.current,
          updated_at: Time.current
        )
        :failed
      end

      def record_refusal(status, message)
        Concierge.logger&.info(
          "[concierge] proposal #{proposal.id} (#{proposal.action_class}) not executed: #{message}"
        )
        proposal.update_columns(execution_error: message, updated_at: Time.current)
        status
      end

      def scope
        return @scope if defined?(@scope)

        @scope = Proposal.scope_for(proposal)
      end

      def executor
        return @executor if defined?(@executor)

        @executor = Proposal.registry.executor_for(proposal.action_class)
      end
    end
  end
end
