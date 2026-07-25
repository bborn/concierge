require "test_helper"

module Concierge
  # Step 1 of the handler order (design §10.7): a signed payload, before anything
  # is written. An endpoint that skipped this would let anyone who learned the URL
  # approve a refund.
  class SlackSignatureTest < ActiveSupport::TestCase
    include Concierge::Test::SlackRequests

    BODY = '{"type":"block_actions"}'.freeze

    setup do
      Concierge.configure { |c| c.slack { signing_secret Concierge::Test::SlackRequests::SECRET } }
    end

    test "a body signed with the configured secret verifies" do
      timestamp = Time.current.to_i

      assert Concierge::Slack::Signature.verify!(
        body: BODY, timestamp: timestamp,
        signature: Concierge::Slack::Signature.sign(body: BODY, timestamp: timestamp)
      )
    end

    test "a signature from another secret is refused" do
      timestamp = Time.current.to_i
      forged = Concierge::Slack::Signature.sign(body: BODY, timestamp: timestamp,
                                                secret: "someone-elses-secret")

      error = assert_raises Concierge::Slack::SignatureError do
        Concierge::Slack::Signature.verify!(body: BODY, timestamp: timestamp, signature: forged)
      end
      assert_match "not signed with this secret", error.message
    end

    test "a tampered body is refused even with a valid signature for the original" do
      timestamp = Time.current.to_i
      signature = Concierge::Slack::Signature.sign(body: BODY, timestamp: timestamp)

      assert_raises Concierge::Slack::SignatureError do
        Concierge::Slack::Signature.verify!(body: '{"type":"block_actions","tampered":1}',
                                            timestamp: timestamp, signature: signature)
      end
    end

    test "a replayed payload is refused outside the five-minute window" do
      # The signature is perfect and stays perfect forever, which is exactly why the
      # window exists: a captured Approve payload must not be re-sendable.
      stale = Time.current.to_i - (Concierge::Slack::Signature::REPLAY_WINDOW + 1)

      error = assert_raises Concierge::Slack::SignatureError do
        Concierge::Slack::Signature.verify!(
          body: BODY, timestamp: stale,
          signature: Concierge::Slack::Signature.sign(body: BODY, timestamp: stale)
        )
      end
      assert_match(/replayed payload/, error.message)
    end

    test "a payload from the future is refused too" do
      ahead = Time.current.to_i + (Concierge::Slack::Signature::REPLAY_WINDOW + 60)

      assert_raises Concierge::Slack::SignatureError do
        Concierge::Slack::Signature.verify!(
          body: BODY, timestamp: ahead,
          signature: Concierge::Slack::Signature.sign(body: BODY, timestamp: ahead)
        )
      end
    end

    test "a request with no signature headers is not a request from Slack" do
      error = assert_raises Concierge::Slack::SignatureError do
        Concierge::Slack::Signature.verify!(body: BODY, timestamp: nil, signature: nil)
      end
      assert_match "unsigned request", error.message
    end

    test "with no configured secret nothing can be trusted" do
      Concierge.reset_config!

      error = assert_raises Concierge::Slack::SignatureError do
        Concierge::Slack::Signature.verify!(body: BODY, timestamp: Time.current.to_i,
                                            signature: "v0=whatever")
      end
      assert_match "no Slack signing secret", error.message
    end

    test "verification reads the headers a Rack request carries" do
      headers = slack_headers(BODY)

      assert Concierge::Slack::Signature.verify!(
        body: BODY,
        headers: { Concierge::Slack::Signature::TIMESTAMP_HEADER =>
                     headers[Concierge::Slack::Signature::TIMESTAMP_HEADER],
                   Concierge::Slack::Signature::SIGNATURE_HEADER =>
                     headers[Concierge::Slack::Signature::SIGNATURE_HEADER] }
      )
    end
  end
end
