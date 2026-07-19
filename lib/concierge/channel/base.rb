module Concierge
  module Channel
    # Base for pluggable delivery channels. Two hard rules (design §3.5):
    #   1. A channel NEVER raises out of #deliver — a broken channel must not take
    #      down a run. The base wraps the subclass hook and swallows errors.
    #   2. A channel declares whether it is #configured? and #available_for? a
    #      subject, so the router can skip it cleanly.
    class Base
      attr_reader :subject

      def initialize(subject:)
        @subject = subject
      end

      # Subclasses set this (e.g. :in_app, :email).
      def name
        raise NotImplementedError
      end

      # Is this channel wired up at all (creds/config present)?
      def configured?
        true
      end

      # Can it reach THIS subject (has an email, an open session, …)?
      def available_for?(_subject)
        true
      end

      # Public entry point — never raises. Returns true on success, false if the
      # channel wasn't usable or the underlying send failed.
      def deliver(payload)
        return false unless configured? && available_for?(subject)

        perform_delivery(payload)
        true
      rescue => e
        Concierge.logger&.error("[concierge] #{name} delivery failed: #{e.class}: #{e.message}")
        false
      end

      private

      # Subclasses implement the actual send here.
      def perform_delivery(_payload)
        raise NotImplementedError
      end
    end
  end
end
