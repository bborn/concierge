module Concierge
  # Turns a run Result into a governed, delivered (or staged) message. This is
  # the one door autonomous outreach goes through: the agent's authority envelope
  # decides WHETHER it may send at all, governance decides IF now, the router
  # decides WHERE, the channel does the send, and we audit the result against the
  # agent that sent it.
  #
  # Returns a status symbol: :delivered, :drafted, :suppressed, :no_channel, or
  # :failed.
  class Outreach
    def self.deliver(result, scope, channel: nil, kind: "outreach", governance: Governance.new)
      new(result, scope, channel: channel, kind: kind, governance: governance).deliver
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

      # Slot 4 — the authority envelope (§10.5). Anything short of :autonomous on
      # the message action class stages the send for a human instead of sending
      # it, so the disputes agent gates while the CSM stays autonomous-within-caps
      # on the same mechanism. §10.6 generalizes this row into an AgentProposal
      # over arbitrary action classes; today it is still the outbox.
      return draft_to_outbox(payload) unless autonomous?

      channel = Channel::Router.new.pick(subject, preferred: @preferred)
      return :no_channel unless channel

      # Mint the unsubscribe token before delivery so the message can carry it,
      # then record the audit row under the same token.
      token = Governance.generate_token
      payload[:unsubscribe_token] = token

      if channel.deliver(payload)
        @governance.record!(@scope, channel: channel.name, kind: @kind, payload: payload, token: token)
        :delivered
      else
        :failed
      end
    end

    private

    def subject
      @scope.subject
    end

    # The legacy global +draft_and_review+ only ever tightens. It is sugar for
    # ":human_approval on the CSM's message class" (§10.5), and a host that flips
    # it on while also declaring agents must not silently get autonomous sends
    # back — a per-agent envelope may tighten further, never loosen past it.
    def autonomous?
      return false if Concierge.config.draft_and_review

      @scope.agent.authority.autonomous?(Authority::MESSAGE_OUTREACH)
    end

    def draft_to_outbox(payload)
      OutboxItem.create!(
        **@scope.key,
        body:    payload[:body],
        channel: @preferred&.to_s,
        kind:    @kind,
        state:   "pending"
      )
      :drafted
    end

    def build_payload
      { body: @result.respond_to?(:reply_text) ? @result.reply_text : @result.to_s, kind: @kind }
    end
  end
end
