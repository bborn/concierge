module Concierge
  module Channel
    # Generic email via ActionMailer — zero third-party deps (design §0.2).
    # Postmark/SendGrid/Lewsnetter are optional drop-in replacements a host wires
    # by swapping this channel. Availability requires an address for the subject,
    # resolved through a host-configured lambda so the gem stays schema-agnostic.
    class Email < Base
      def name
        :email
      end

      def configured?
        Concierge.config.email_address_for.present?
      end

      def available_for?(subject)
        address_for(subject).present?
      end

      private

      def perform_delivery(payload)
        # Pass only serializable primitives — deliver_later serializes every
        # mailer param through ActiveJob, and a Concierge::Subject is not
        # serializable. The mailer only needs the address, payload, and token.
        Concierge::OutreachMailer
          .with(
            to: address_for(subject),
            payload: payload,
            unsubscribe_token: payload[:unsubscribe_token]
          )
          .notify
          .deliver_later
      end

      def address_for(subject)
        resolver = Concierge.config.email_address_for
        resolver&.call(subject)
      end
    end
  end
end
