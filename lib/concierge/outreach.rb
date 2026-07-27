module Concierge
  # Turns a run Result into a governed, delivered (or staged) message. This is
  # the one door autonomous outreach goes through: the agent's authority envelope
  # decides WHETHER it may send at all, governance decides IF now, the router
  # decides WHERE, the channel does the send, and we audit the result against the
  # agent that sent it.
  #
  # Returns a status symbol: :delivered, :drafted, :suppressed, :blocked_by_rule,
  # :no_channel, or :failed.
  class Outreach
    def self.deliver(result, scope, channel: nil, kind: "outreach", governance: Governance.new)
      new(result, scope, channel: channel, kind: kind, governance: governance).deliver
    end

    # The send itself, with the authority question already answered. #deliver asks
    # it before reaching here; Proposal::Execute asks it of an *approved* row and
    # then calls this. One door either way, so a message that went through a human
    # is delivered and audited exactly like one that did not.
    #
    # Returns :delivered, :no_channel or :failed.
    def self.dispatch(scope, payload, channel: nil, kind: "outreach", governance: Governance.new)
      scope   = Scope.coerce(scope)
      channel = Channel::Router.new.pick(scope.subject, preferred: channel)
      return :no_channel unless channel

      # Mint the unsubscribe token before delivery so the message can carry it,
      # then record the audit row under the same token.
      token   = Governance.generate_token
      payload = payload.merge(unsubscribe_token: token)

      # The audit row goes in BEFORE the send, and is rolled back if the send
      # fails — rather than after a send that succeeded.
      #
      # The payload is the only thing a channel is handed, and it says what was
      # said, not who said it: no agent, no timestamp. That is fine for email,
      # which renders one message into a mailbox. It is not fine for in-app,
      # which has to render "Bill · billing · 14:02" onto a live page, because
      # Bill and Kit are different agents with different personas and authority
      # (§10.1) and the customer is owed the difference. The only place that
      # knows is this delivery row — so a host asked to surface a message while
      # its own ledger entry does not exist yet is a host that cannot surface it,
      # which is how in-app came to only ever persist.
      #
      # The trade, plainly: a crash between the write and the send now leaves a
      # row for a message that may not have gone out, where before it lost the
      # row for a message that may have. For a ledger whose job is frequency caps
      # and quiet hours, over-counting errs toward silence and under-counting
      # errs toward pestering someone. This is the better way to be wrong.
      delivery = governance.record!(scope, channel: channel.name, kind: kind,
                                           payload: payload, token: token)

      return :delivered if channel.deliver(payload)

      delivery.destroy
      :failed
    end

    def initialize(result, scope, channel:, kind:, governance:)
      @result     = result
      @scope      = Scope.coerce(scope)
      @preferred  = channel
      @kind       = kind
      @governance = governance
    end

    def deliver
      payload = build_payload
      return :suppressed unless @governance.usefulness_ok?(payload)
      return :suppressed unless @governance.allow?(@scope, kind: @kind)
      return :blocked_by_rule unless guards_clear?(payload)

      # Slot 4 — the authority envelope (§10.5). Anything short of :autonomous on
      # the message action class stages the send for a human instead of sending
      # it, so the disputes agent gates while the CSM stays autonomous-within-caps
      # on the same mechanism. The staged row is an AgentProposal over the
      # "message.outreach" action class (§10.6) — the same object a record update
      # or a refund is staged as.
      return stage_proposal(payload) unless autonomous?

      self.class.dispatch(@scope, payload, channel: @preferred, kind: @kind,
                                           governance: @governance)
    end

    private

    def subject
      @scope.subject
    end

    # A rule that graduated to +enforcement: "guard"+ is checked by the engine,
    # not left to the model's discretion (design §10.2). This is the one action
    # class the engine dispatches itself today; §10.6's Proposal::Execute re-checks
    # the same predicates for host-registered executors.
    #
    # Nothing is guarded unless a human activated a guard rule with a predicate,
    # so this is inert on a host that has none.
    def guards_clear?(payload)
      violated = Rules.guard_violations(@scope, action_class: Authority::MESSAGE_OUTREACH,
                                                payload: payload)
      return true if violated.empty?

      Concierge.logger&.info(
        "[concierge] #{@scope.agent_slug} send blocked by guard rule(s) " \
        "#{violated.map(&:id).join(', ')} for #{subject.grain}##{subject.id}"
      )
      false
    end

    # The *effective* level, which is Agent#level_for's job: the per-agent
    # envelope with the legacy global +draft_and_review+ tightening folded in. Read
    # through one method so the staging decision here and the gate snapshotted onto
    # the proposal can never disagree about what this agent was allowed to do.
    def autonomous?
      @scope.agent.autonomous?(Authority::MESSAGE_OUTREACH)
    end

    # Stage the send as a proposal a human has to approve. The channel travels in
    # the payload rather than being picked now: the approval may land hours later,
    # and which channel can reach this account is a question worth asking at
    # execution time.
    def stage_proposal(payload)
      Proposal.propose(
        @scope,
        action_class:     Authority::MESSAGE_OUTREACH,
        payload:          payload.merge(channel: @preferred&.to_s).compact,
        rule_ids_applied: (@result.rule_ids_applied if @result.respond_to?(:rule_ids_applied)),
        agent_run:        (@result.run_record if @result.respond_to?(:run_record))
      )
      :drafted
    end

    # The words, plus the host's own buttons the agent asked to have shown with
    # them (docs/design/message-actions.md). +actions+ is present only when there
    # are some, so a host that declared no vocabulary sees the payload it always
    # saw — and every value in it originated in that host's config, not in the
    # model: the agent named keys and the engine resolved them.
    def build_payload
      body    = @result.respond_to?(:reply_text) ? @result.reply_text : @result.to_s
      payload = { body: body, kind: @kind }
      offered = @result.respond_to?(:actions_offered) ? Array(@result.actions_offered) : []

      offered.any? ? payload.merge(actions: offered.map(&:to_payload)) : payload
    end
  end
end
