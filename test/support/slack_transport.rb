module Concierge
  module Test
    # A recording stand-in for the Slack Web API. Wired via
    # `config.slack { transport … }`, which is the seam Concierge::Slack::Client
    # already reaches for — so the suite exercises the real client, the real card
    # builder and the real handler order, and only the socket is fake.
    #
    # It can also *observe the ordering the spec cares about*: every call snapshots
    # the state of the proposal rows at the moment it was made, so a test can prove
    # the decision was already written (and executed) before the card was updated,
    # rather than trusting that the code reads that way.
    class SlackTransport
      Call = Struct.new(:method, :payload, :proposal_states, keyword_init: true)

      attr_reader :calls
      attr_accessor :fail_with

      def initialize(&responder)
        @calls     = []
        @responder = responder
        @ts        = 1_700_000_000
      end

      def to_proc
        method(:call).to_proc
      end

      def call(method, payload)
        @calls << Call.new(method: method, payload: payload, proposal_states: proposal_states)
        raise fail_with if fail_with

        @responder&.call(method, payload) || default_response(method, payload)
      end

      def calls_to(method)
        calls.select { |call| call.method == method }
      end

      def last(method) = calls_to(method).last

      def posted_texts
        calls_to("chat.postMessage").map { |call| call.payload[:text] }
      end

      # Every block of every message posted or updated, flattened — so a test can
      # assert on what a human would actually see without walking Block Kit.
      def rendered(method = nil)
        (method ? calls_to(method) : calls).flat_map { |call| Array(call.payload[:blocks]) }
                                           .map { |block| JSON.generate(block) }.join("\n")
      end

      private

      def proposal_states
        Concierge::AgentProposal.order(:id).pluck(:id, :state, :executed_at).to_h do |id, state, executed_at|
          [ id, { state: state, executed: !executed_at.nil? } ]
        end
      end

      def default_response(method, payload)
        case method
        when "chat.postMessage"
          { "ok" => true, "channel" => payload[:channel], "ts" => next_ts }
        else
          { "ok" => true }
        end
      end

      def next_ts
        @ts += 1
        format("%d.000100", @ts)
      end
    end

    # Signs a body the way Slack does, so an integration test posts a genuinely
    # verifiable request rather than stubbing the verifier out. A test that skipped
    # the signature would be the crutch that hides a missing check.
    module SlackRequests
      SECRET = "test-slack-signing-secret".freeze

      def slack_headers(body, secret: SECRET, timestamp: Time.current.to_i)
        {
          "CONTENT_TYPE" => "application/json",
          Concierge::Slack::Signature::TIMESTAMP_HEADER => timestamp.to_s,
          Concierge::Slack::Signature::SIGNATURE_HEADER =>
            Concierge::Slack::Signature.sign(body: body, timestamp: timestamp, secret: secret)
        }
      end

      def slack_form_headers(body, secret: SECRET, timestamp: Time.current.to_i)
        slack_headers(body, secret: secret, timestamp: timestamp)
          .merge("CONTENT_TYPE" => "application/x-www-form-urlencoded")
      end
    end
  end
end
