module Concierge
  module Test
    # Drives the **real** RubyLLM path with only the HTTP POST replaced.
    #
    # FakeChat stands in for the whole chat object, which is exactly right for
    # prompt-assembly and tool-loop assertions — but it means the suite never
    # exercises +acts_as_chat+, so anything that depends on the host's messages
    # actually being persisted is invisible to it. That is the shape of the bug
    # that hid for a phase (see task #14): a green suite over a path the online
    # host never takes.
    #
    # Here the only thing faked is the network hop. Everything the run touches
    # after it — RubyLLM::Chat, the Anthropic response parser, the
    # +before_message+/+after_message+ callbacks that write the host's Chat and
    # Message rows — is the real code an online host runs.
    #
    # Anything that reaches the network *without* a scripted reply raises, so a
    # test can never silently make a real request.
    module StubbedProvider
      class NetworkReached < StandardError; end

      # Faraday's response surface, as much of it as the provider reads.
      Response = Struct.new(:body, :status, :headers)

      module Interception
        def post(url, payload, &)
          raise Thread.current[:concierge_stubbed_error] if Thread.current[:concierge_stubbed_error]

          body = Thread.current[:concierge_stubbed_completion]
          raise NetworkReached, "a test tried to POST #{url} with no scripted reply" unless body

          Thread.current[:concierge_last_request] = payload
          Response.new(body, 200, {})
        end

        def get(url, &)
          raise NetworkReached, "a test tried to GET #{url}"
        end
      end

      RubyLLM::Connection.prepend(Interception)

      # Runs the block with one scripted Anthropic completion in place. The body
      # is the provider's own wire format, so the parser does its real work.
      def with_model_reply(text, input_tokens: 12, output_tokens: 7, model: "claude-sonnet-4-5")
        Thread.current[:concierge_last_request] = nil
        Thread.current[:concierge_stubbed_completion] = {
          "id" => "msg_stub", "type" => "message", "role" => "assistant", "model" => model,
          "content" => [ { "type" => "text", "text" => text } ],
          "stop_reason" => "end_turn",
          "usage" => { "input_tokens" => input_tokens, "output_tokens" => output_tokens }
        }
        yield
      ensure
        Thread.current[:concierge_stubbed_completion] = nil
      end

      # The other half: a turn that reaches the provider and comes back a failure,
      # over the same real RubyLLM path. A double that raises instead of the chat
      # would skip the persistence callbacks entirely, which is exactly what has to
      # be under test when the question is "what did a failed turn leave behind?"
      def with_model_error(error = RubyLLM::Error.new(nil, "the provider fell over"))
        Thread.current[:concierge_stubbed_error] = error
        yield
      ensure
        Thread.current[:concierge_stubbed_error] = nil
      end

      # What the provider actually put on the wire for the most recent turn.
      #
      # The conversation the model is *shown* is the thing this whole seam is
      # about: it is rebuilt from the host's persisted rows on every turn, so a
      # dropped row is invisible in the reply and only shows up here. Asserting on
      # the reply alone is how a one-sided transcript stayed green for a phase.
      def last_request_messages
        payload = Thread.current[:concierge_last_request] or return []

        (payload[:messages] || payload["messages"] || []).map do |message|
          { role: (message[:role] || message["role"]).to_s,
            text: message_text(message[:content] || message["content"]) }
        end
      end

      def message_text(content)
        case content
        when String then content
        when Array  then content.filter_map { |part| part[:text] || part["text"] }.join("\n")
        else             content.to_s
        end
      end

      # The host chat_factory an online host actually runs: resume the persisted
      # conversation through acts_as_chat. Point config.chat_factory at this to
      # take FakeChat out of the loop for one test.
      def persisting_chat_factory
        Concierge::Configuration::DEFAULT_CHAT_FACTORY
      end
    end
  end
end

ActiveSupport::TestCase.include Concierge::Test::StubbedProvider
