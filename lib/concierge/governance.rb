require "securerandom"

module Concierge
  # The rules that keep an autonomous agent from over-messaging: opt-out,
  # frequency caps, quiet hours, and a usefulness bar (no-op discipline). All
  # outbound delivery goes through here (design §3.5).
  class Governance
    # Minimum spacing between sends of the same kind, by the subject's chosen
    # cadence. Host-overridable via config.frequency_windows.
    DEFAULT_WINDOWS = {
      "off"    => nil,        # never
      "less"   => 7 * 86_400, # weekly
      "normal" => 86_400,     # daily
      "more"   => 3_600       # hourly
    }.freeze

    def initialize(delivery_model: Concierge::ChannelDelivery, now: nil)
      @deliveries = delivery_model
      @now        = now
    end

    # May we send this kind to this subject right now? Takes a Scope or a bare
    # Subject, but every rule here is deliberately read at the *subject* level:
    # the customer has one inbox, one opt-out, and one quiet-hours window, and
    # per-agent frequency caps would let two agents each send "within cap" while
    # the customer got twice as much mail. Content namespaces are per-agent
    # (§10.3); the governance rails are per-customer.
    def allow?(subject, kind: "outreach")
      pref = OutreachPreference.for(subject)
      return false if pref.opted_out
      return false if within_quiet_hours?(pref)
      return false unless frequency_ok?(subject, pref, kind)

      true
    end

    # Is the message worth sending at all? Default bar: non-blank body. Hosts can
    # raise the bar with config.usefulness_check.
    def usefulness_ok?(payload)
      custom = Concierge.config.usefulness_check
      return custom.call(payload) if custom

      payload[:body].to_s.strip.length.positive?
    end

    # Record a send (audit + the frequency-cap ledger), attributed to the agent
    # that sent it. Returns the row. The unsubscribe token is generated here
    # unless the caller minted one earlier (email needs it before the send).
    def record!(scope, channel:, kind: "outreach", payload: {}, token: nil)
      @deliveries.create!(
        **Scope.coerce(scope).key,
        channel:           channel.to_s,
        kind:              kind.to_s,
        sent_at:           now,
        unsubscribe_token: token || self.class.generate_token,
        payload_digest:    digest(payload)
      )
    end

    def self.generate_token
      SecureRandom.urlsafe_base64(24)
    end

    private

    def now
      @now || Time.current
    end

    def within_quiet_hours?(pref)
      start = pref.quiet_hours_start
      finish = pref.quiet_hours_end
      return false if start.nil? || finish.nil?

      hour = now.hour
      if start <= finish
        hour >= start && hour < finish
      else # window wraps midnight, e.g. 22 -> 7
        hour >= start || hour < finish
      end
    end

    def frequency_ok?(subject, pref, kind)
      window = windows[pref.frequency]
      return false if pref.frequency == "off"
      return true  if window.nil?

      # Across every agent, on purpose — see #allow?.
      last = @deliveries.where(Scope.subject_key(subject)).of_kind(kind).maximum(:sent_at)
      last.nil? || (now - last) >= window
    end

    def windows
      Concierge.config.frequency_windows || DEFAULT_WINDOWS
    end

    def digest(payload)
      require "digest"
      Digest::SHA256.hexdigest(payload.to_s)[0, 32]
    end
  end
end
