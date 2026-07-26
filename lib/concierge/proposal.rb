require "digest"
require "securerandom"

module Concierge
  # The proposal lifecycle (design §10.6). An agent's authority envelope (§10.5)
  # decides whether it may perform an action class at all; anything short of
  # +:autonomous+ lands here instead — as a row a human has to look at.
  #
  #   Proposal.propose(scope, action_class: "money.refund",
  #                    payload: { order_id: 42, amount_cents: 2500 })
  #   ApprovalIntake.approve(proposal, by: "sam@acme.test")   # -> Proposal::Execute
  #
  # Three things this class refuses to do, on purpose:
  #
  # - **Propose an autonomous action.** If the envelope says the agent may just do
  #   it, a proposal is a row nobody ever has to read. The caller is told to
  #   execute directly rather than being handed a queue entry that means nothing.
  # - **Approve anything.** Approval is Concierge::ApprovalIntake's job, because
  #   it is a human act and belongs on the seam surfaces drive (§10.7).
  # - **Execute anything.** Proposal::Execute reads an +approved+ row. There is no
  #   path that approves and executes without the row in between.
  class Proposal
    # An actor, a state, or an authority level that forbids what was asked.
    class GateError < Concierge::Error; end

    # The world moved between propose and execute (§10.6). Raised by nothing —
    # Execute returns a status — but defined so a host executor can signal the
    # same condition from inside its own invariant checks.
    class PreconditionFailed < Concierge::Error; end

    class << self
      # Stage an action for a human. Always lands in +proposed+; this method has
      # no path to +approved+, deliberately.
      #
      # +created_by+ defaults to the agent itself, written with the reserved
      # +agent:+ prefix Concierge::Rules already uses — an actor with that prefix
      # can propose but can never approve, which is what makes maker-checker
      # structural rather than conventional.
      #
      # +idempotency_key+ is minted per proposal unless the caller supplies one.
      # Supplying a deterministic key makes *proposing* idempotent too: a second
      # call with the same key returns the existing row instead of stacking a
      # duplicate card (the at-least-once-delivery lesson from §10.2's job).
      # The key is scoped to the (Agent × Subject) pair, so a host is free to
      # derive one from a domain id — +"plan-change-#{order_id}"+ — without having
      # to remember to namespace it by agent and account itself.
      def propose(target, action_class:, payload: {}, created_by: nil, precondition: nil,
                  rule_ids_applied: nil, agent_run: nil, idempotency_key: nil,
                  expires_in: :default)
        scope        = Scope.coerce(target)
        action_class = action_class.to_s
        gate         = gate_for(scope, action_class)

        # Scoped, like every other read in the phase (§10.12). A key is only ever
        # meaningful inside the cell that minted it: deduping globally would hand
        # this caller another (agent, account)'s row and never stage the action it
        # actually asked for.
        existing = idempotency_key && AgentProposal.for_scope(scope)
                                                   .find_by(idempotency_key: idempotency_key)
        return existing if existing

        notify(AgentProposal.create!(
          **scope.key,
          action_class:        action_class,
          payload:            stringify(payload),
          gate:               gate.to_s,
          state:              "proposed",
          created_by:         (created_by || Rules.agent_actor(scope.agent_slug)).to_s,
          idempotency_key:    idempotency_key || SecureRandom.hex(16),
          precondition_digest: precondition_digest(scope, action_class, payload, precondition),
          # The rules the *run* said it applied (§10.4), not every rule in force:
          # this column carries the agent's own claim through to the approval
          # card, so a human can see what the draft was steered by.
          rule_ids_applied:   Array(rule_ids_applied),
          agent_run_id:       agent_run&.id,
          expires_at:         expiry(expires_in)
        ))
      end

      # The authority level that governs this action class for this agent,
      # snapshotted onto the row at propose time so a later config change cannot
      # retroactively loosen a proposal that is already waiting.
      def gate_for(scope, action_class)
        level = scope.agent.level_for(action_class)
        return level unless level == :autonomous

        raise GateError,
              "#{scope.agent_slug} is :autonomous on #{action_class}, so there is nothing " \
              "to propose — execute it directly. Gate the action class in the agent's " \
              "authority block if it should stage for a human."
      end

      # Where hosts register executors and preconditions per action class
      # (§10.6/§10.8). Lives on the Configuration so it resets with it.
      def registry
        Concierge.config.proposals
      end

      # Rebuild the (Agent × Subject) Scope a row was written under. The agent
      # travels as a slug and the subject as an id, because a row has to outlive
      # the process that wrote it.
      #
      # Returns nil when either side no longer resolves — an agent removed from
      # config, or a deleted account. That is inert data, not an error (step-0
      # spike §A1), and Execute treats it as a refusal rather than a crash.
      def scope_for(proposal)
        agent = Concierge.config.agent(proposal.agent_slug)
        return unless agent

        subject = Concierge.config.account&.find_subject(proposal.subject_id)
        return unless subject

        Scope.new(agent, subject)
      rescue StandardError => e
        Concierge.logger&.warn("[concierge] could not resolve scope for proposal " \
                               "#{proposal.id}: #{e.class}: #{e.message}")
        nil
      end

      # The current value of whatever this action class declared as its
      # precondition, digested. Nil when the class declared none — then there is
      # nothing to re-validate, and Execute says so rather than pretending it
      # checked.
      def current_precondition_digest(proposal, scope: nil)
        scope ||= scope_for(proposal)
        return unless scope

        resolver = registry.precondition_for(proposal.action_class)
        return unless resolver

        digest(invoke(resolver, scope, proposal.action_arguments))
      end

      # A stable digest of the state a proposal assumed. Sorted, so two equal
      # hashes built in different orders never read as a changed world.
      def digest(state)
        return if state.nil?

        Digest::SHA256.hexdigest(canonical(state))[0, 32]
      end

      # Retire proposals nobody acted on in time. Called by SweepJob, so a host
      # that sets +config.proposal_ttl+ gets expiry from the recurring job it
      # already registered. Never touches an approved row: something approved has
      # been decided, and expiring it would quietly reverse a human.
      def expire_stale!(now: Time.current)
        stale = AgentProposal.past_due(now).to_a
        stale.each do |proposal|
          proposal.update_columns(state: "expired", updated_at: now)
          Concierge.logger&.info(
            "[concierge] proposal #{proposal.id} (#{proposal.action_class}) expired unapproved"
          )
        end
        stale.size
      end

      # Call a host-registered callable that may declare one argument or two. A
      # precondition usually only needs the scope; one that depends on which
      # record is being touched needs the payload too.
      def invoke(callable, scope, payload)
        callable.arity == 1 ? callable.call(scope) : callable.call(scope, payload)
      end

      # An executor gets the proposal — which carries the action's arguments — and
      # the resolved Scope, so it never has to look up the account by a raw id
      # (the isolation rule of §6: no seam takes a foreign id it resolves
      # globally). One-argument executors are accepted for the common case.
      def invoke_executor(executor, proposal, scope)
        executor.arity == 1 ? executor.call(proposal) : executor.call(proposal, scope)
      end

      private

      # "Posts an approval card." Whether that is Slack, an Avo screen or email is
      # the host's call; the engine's job is to make the card exist and be
      # addressable, which /concierge/admin/proposals already does. A notifier is a
      # side channel, so a broken one must never lose the proposal.
      def notify(proposal)
        Concierge.config.proposal_notifier&.call(proposal)
        proposal
      rescue StandardError => e
        Concierge.logger&.warn("[concierge] proposal_notifier raised #{e.class}: #{e.message}")
        proposal
      end

      def precondition_digest(scope, action_class, payload, explicit)
        return digest(stringify(explicit)) if explicit

        resolver = registry.precondition_for(action_class)
        return unless resolver

        digest(invoke(resolver, scope, symbolize(payload)))
      end

      def expiry(expires_in)
        ttl = expires_in == :default ? Concierge.config.proposal_ttl : expires_in
        return unless ttl

        Time.current + ttl
      end

      # JSON round-trips string keys, so normalize on the way in: a payload that
      # reads back differently than it was written is a whole class of bug in an
      # object whose entire job is "do exactly what was approved."
      def stringify(hash)
        (hash || {}).to_h { |key, value| [ key.to_s, value ] }
      end

      def symbolize(hash)
        (hash || {}).to_h { |key, value| [ key.to_sym, value ] }
      end

      def canonical(value)
        case value
        when Hash  then "{#{value.map { |k, v| "#{k}=#{canonical(v)}" }.sort.join(',')}}"
        when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
        else value.to_s
        end
      end
    end
  end
end
