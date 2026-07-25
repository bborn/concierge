require "json"
require "net/http"
require "uri"

module Concierge
  module Slack
    # The Slack Web API calls this seam needs, and no more: post a card, update a
    # card in place once it is decided, and open the modal that collects a
    # rejection reason or a correction.
    #
    # The transport is a seam (`config.slack { transport ->(method, payload) { … } }`)
    # so the suite — and a host that routes through its own Slack plumbing — never
    # makes an HTTP request. Without one, real HTTP with the bot token.
    #
    # This class **raises** on refusal, unlike Channel::Base. That is the §10.7
    # split in one line: an outbound delivery must never take a run down with it,
    # but a card that silently failed to post is an approval nobody will ever see,
    # and the caller (the notifier) is the one that decides what to record.
    class Client
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 5

      def initialize(settings = Concierge::Slack.settings)
        @settings = settings
      end

      # A new card. `thread_ts` threads it under the case (§2.6) — one thread per
      # (agent, account) — so a channel reads as a list of accounts.
      def post_message(channel:, blocks:, text:, thread_ts: nil)
        call("chat.postMessage", {
          channel: channel,
          text:    Text.safe(text, limit: 200),
          blocks:  blocks,
          thread_ts: thread_ts,
          # A threaded card stays in the thread. Broadcasting every card back to
          # the channel would defeat the threading it just did.
          reply_broadcast: false,
          unfurl_links: false,
          unfurl_media: false
        }.compact)
      end

      # Replace a card's contents in place — how a decided proposal stops offering
      # buttons that would now be refused.
      def update_message(channel:, ts:, blocks:, text:)
        call("chat.update", channel: channel, ts: ts, blocks: blocks,
                            text: Text.safe(text, limit: 200))
      end

      # Open a modal. Reject-with-a-reason and correct-then-approve both need one:
      # a button alone cannot carry free text, and §2.5 requires a reason.
      def open_view(trigger_id:, view:)
        call("views.open", trigger_id: trigger_id, view: view)
      end

      # Ephemeral, visible only to the person who clicked. This is how a refusal
      # gets back to a human — a maker-checker rejection has to be *readable*, and
      # the channel does not need to watch someone be told no.
      def post_ephemeral(channel:, user:, text:)
        call("chat.postEphemeral", channel: channel, user: user,
                                   text: Text.safe(text, limit: 1000))
      end

      private

      attr_reader :settings

      def call(method, payload = {})
        response = transport_for(method).call(method, payload)
        body     = (response || {}).transform_keys(&:to_s)
        return body if body["ok"]

        raise ApiError, "Slack #{method} refused: #{body['error'] || body.inspect}"
      end

      def transport_for(method)
        settings.transport || ->(name, payload) { http(name, payload) }
      end

      def http(method, payload)
        token = settings.bot_token.to_s
        raise ApiError, "no Slack bot token is configured, so #{method} cannot be called" if token.empty?

        uri = URI.join("#{settings.api_url}/", method)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"]  = "application/json; charset=utf-8"
        request.body = JSON.generate(payload)

        JSON.parse(perform(uri, request))
      rescue JSON::ParserError => e
        raise ApiError, "Slack #{method} returned an unparseable body: #{e.message}"
      end

      def perform(uri, request)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT,
                                            read_timeout: READ_TIMEOUT) do |http|
          http.request(request).body
        end
      rescue StandardError => e
        raise ApiError, "Slack #{uri.path} was unreachable: #{e.class}: #{e.message}"
      end
    end
  end
end
