module Concierge
  # Slack as the **remote control** for the approval queue (design §10.7,
  # OfferLab §2.6). Two things this is not, both deliberate:
  #
  # - **Not a ChannelBridge.** `Channel::Base` is outbound-only ("never raises,
  #   deliver + audit") and that stays. An approval card is inbound as much as
  #   outbound, and the click that comes back is not a delivery — it is a
  #   decision. Overloading the channel abstraction with interactivity is how a
  #   never-raising delivery path acquires a code path that must fail loudly.
  # - **Not an incoming webhook.** A webhook can post a message and nothing else;
  #   it cannot tell you *who clicked*, and an approval whose approver is unknown
  #   is not maker-checked. This needs a real Slack app: a signed events endpoint
  #   and a signed interactivity endpoint.
  #
  # What Slack is allowed to be, exactly: a surface that authenticates a human and
  # calls Concierge::ApprovalIntake. It holds a transport and no policy — the same
  # contract /concierge/admin/proposals already honours, which is what makes a
  # Slack outage cost convenience and not authority.
  #
  #   Concierge.configure do |c|
  #     c.slack do
  #       signing_secret ENV["SLACK_SIGNING_SECRET"]
  #       bot_token      ENV["SLACK_BOT_TOKEN"]
  #
  #       channel :csm,     "C0CSM"        # one channel per agent
  #       channel :billing, "C0BILLING"
  #
  #       daily_card_cap 20
  #       actor_for ->(user) { User.find_by(slack_id: user["id"])&.email }
  #     end
  #
  #     c.proposal_notifier = Concierge::Slack::Notifier
  #   end
  module Slack
    # The payload was not signed by Slack — a bad secret, a tampered body, or a
    # replayed request. The endpoints answer 401 and do nothing else.
    class SignatureError < Concierge::Error; end

    # Slack itself refused, or could not be reached.
    class ApiError < Concierge::Error; end

    # Per-agent, per-day. A cap and not a rate limit: the point is that a business
    # function cannot make a channel unreadable, and the number an operator wants
    # to reason about is "cards per day from this agent."
    DEFAULT_DAILY_CARD_CAP = 20

    # The one block a host configures. Setter-when-called-with-a-value,
    # reader-when-called-bare, like every other Concierge config block.
    class Settings
      extend Concierge::DSL

      dsl_value :signing_secret
      dsl_value :bot_token
      dsl_value :api_url
      dsl_value :daily_card_cap
      dsl_value :actor_for
      dsl_value :transport

      def initialize
        @channels       = {}
        @api_url        = "https://slack.com/api"
        @daily_card_cap = DEFAULT_DAILY_CARD_CAP
      end

      # One channel per agent (§2.6). Called with an id it declares the mapping;
      # called bare it reads it back.
      #
      # An agent with no channel simply gets no cards — its proposals still queue
      # in the admin. That is the right default for a host that wires Slack up for
      # one business function before the others.
      def channel(agent_slug, channel_id = nil)
        key = agent_slug.to_s
        @channels[key] = channel_id.to_s if channel_id
        # A blank id is not a channel. Reading it back as one would post cards into
        # the void and report them as delivered.
        @channels[key].presence
      end

      def channels
        @channels.select { |_slug, id| id.present? }
      end

      # Configured enough to receive a signed payload. Without a signing secret
      # there is no way to know a request came from Slack, so the endpoints fail
      # closed (404) rather than trusting the body.
      def configured?
        signing_secret.to_s.strip.present?
      end

      # Configured enough to *post*. Reading and writing are separately gated on
      # purpose: a host can accept decisions from a Slack app whose cards another
      # system posts.
      def can_post?
        bot_token.to_s.strip.present? || transport.present?
      end

      # Who clicked, as an actor string the audit trail can live with. The host
      # maps a Slack user onto its own identity; without a mapping the Slack user
      # id *is* the identity, which is honest (it is exactly who clicked) and
      # still satisfies maker-checker, since it can never collide with the
      # reserved `agent:` prefix.
      def actor(user)
        user = (user || {}).transform_keys(&:to_s)
        mapped = actor_for&.call(user)
        return mapped.to_s.strip if mapped.to_s.strip.present?

        id = user["id"].to_s.strip
        id.present? ? "slack:#{id}" : ""
      rescue StandardError => e
        Concierge.logger&.warn("[concierge] slack actor_for raised #{e.class}: #{e.message}")
        ""
      end
    end

    class << self
      def settings
        Concierge.config.slack
      end

      def configured? = settings.configured?

      # The channel this agent's cards go to, or nil.
      def channel_for(agent_slug)
        settings.channel(agent_slug)
      end
    end
  end
end
