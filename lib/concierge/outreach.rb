module Concierge
  # Turns a run Result into a governed, delivered (or suppressed) message. This
  # is the one door autonomous outreach goes through: governance decides IF, the
  # router decides WHERE, the channel does the send, and we audit the result.
  #
  # Returns a status symbol: :delivered, :suppressed, :no_channel, or :failed.
  class Outreach
    def self.deliver(result, subject, channel: nil, kind: "outreach", governance: Governance.new)
      new(result, subject, channel: channel, kind: kind, governance: governance).deliver
    end

    def initialize(result, subject, channel:, kind:, governance:)
      @result     = result
      @subject    = subject
      @preferred  = channel
      @kind       = kind
      @governance = governance
    end

    def deliver
      payload = build_payload
      return :suppressed unless @governance.usefulness_ok?(payload)
      return :suppressed unless @governance.allow?(@subject, kind: @kind)

      channel = Channel::Router.new.pick(@subject, preferred: @preferred)
      return :no_channel unless channel

      # Mint the unsubscribe token before delivery so the message can carry it,
      # then record the audit row under the same token.
      token = Governance.generate_token
      payload[:unsubscribe_token] = token

      if channel.deliver(payload)
        @governance.record!(@subject, channel: channel.name, kind: @kind, payload: payload, token: token)
        :delivered
      else
        :failed
      end
    end

    private

    def build_payload
      { body: @result.respond_to?(:reply_text) ? @result.reply_text : @result.to_s, kind: @kind }
    end
  end
end
