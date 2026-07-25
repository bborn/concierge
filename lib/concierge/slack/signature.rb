require "openssl"

module Concierge
  module Slack
    # Slack request signing (design §10.7: "signed payload" is the *first* step of
    # the handler, before anything is written). Slack signs the raw body with the
    # app's signing secret; an endpoint that skipped this would let anyone who
    # learned the URL approve a refund.
    #
    #   Signature.verify!(body: request.raw_post, headers: request.headers)
    #
    # Three refusals, all raising SignatureError:
    #
    #   1. **Nothing to verify.** A missing timestamp or signature header is not a
    #      request from Slack.
    #   2. **Replay.** A signature stays valid forever, so a captured payload
    #      could be re-sent to re-approve something. Slack's own guidance is a
    #      five-minute window; outside it the request is refused even when the
    #      HMAC is perfect.
    #   3. **Mismatch.** Compared in constant time — a byte-at-a-time comparison
    #      of an HMAC is an oracle for forging one.
    module Signature
      VERSION            = "v0".freeze
      TIMESTAMP_HEADER   = "X-Slack-Request-Timestamp".freeze
      SIGNATURE_HEADER   = "X-Slack-Signature".freeze
      REPLAY_WINDOW      = 5 * 60

      class << self
        def verify!(body:, timestamp: nil, signature: nil, headers: nil,
                    secret: nil, now: Time.current)
          timestamp ||= headers && headers[TIMESTAMP_HEADER]
          signature ||= headers && headers[SIGNATURE_HEADER]
          secret    ||= Concierge::Slack.settings.signing_secret

          if secret.to_s.strip.empty?
            raise SignatureError, "no Slack signing secret is configured, so no payload can be trusted"
          end
          if timestamp.to_s.strip.empty? || signature.to_s.strip.empty?
            raise SignatureError, "unsigned request: #{TIMESTAMP_HEADER} and #{SIGNATURE_HEADER} are both required"
          end

          assert_fresh!(timestamp, now)
          assert_matches!(body, timestamp, signature, secret)
          true
        end

        # What Slack should have sent for this body, so a host (and the test
        # suite) can sign a payload the same way Slack does.
        def sign(body:, timestamp:, secret: nil)
          secret ||= Concierge::Slack.settings.signing_secret
          digest = OpenSSL::HMAC.hexdigest("sha256", secret.to_s,
                                           "#{VERSION}:#{timestamp}:#{body}")
          "#{VERSION}=#{digest}"
        end

        private

        def assert_fresh!(timestamp, now)
          age = (now.to_i - timestamp.to_i).abs
          return if timestamp.to_i.positive? && age <= REPLAY_WINDOW

          raise SignatureError,
                "Slack timestamp #{timestamp.inspect} is #{age}s from now (window " \
                "#{REPLAY_WINDOW}s) — a replayed payload must not be able to re-decide anything"
        end

        def assert_matches!(body, timestamp, signature, secret)
          expected = sign(body: body.to_s, timestamp: timestamp, secret: secret)
          return if ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)

          raise SignatureError, "Slack signature mismatch: the body was not signed with this secret"
        end
      end
    end
  end
end
