module Concierge
  module Slack
    # Anti-noise, at the last possible moment (§2.6: "no bare @channel"). Every
    # string this engine puts into Slack goes through here, because most of them
    # are not written by us: a proposal's payload is a draft the *model* wrote, and
    # a model that emits `<!channel>` would otherwise ping a whole channel about
    # one account's invoice.
    #
    # The escapes are neutralized rather than deleted — an operator should still
    # see that the draft tried to shout, since a draft that wants to ping everyone
    # is a signal about the agent, not a rendering detail.
    module Text
      # Slack only notifies on its escape syntax, never on a literal "@channel",
      # so rewriting the escape into the literal is exactly enough.
      BROADCASTS = {
        "<!channel>"  => "@channel",
        "<!here>"     => "@here",
        "<!everyone>" => "@everyone"
      }.freeze

      # <!subteam^S123|@oncall> pings a user group; the trailing label is what a
      # human reads, so keep that and drop the ping.
      SUBTEAM = /<!subteam\^[^|>]+(?:\|([^>]*))?>/

      # Slack rejects text blocks over 3000 characters outright, and a card is a
      # summary a human decides from — not the archive. The full payload is on the
      # proposal row and the admin screen.
      LIMIT = 2800

      class << self
        def safe(value, limit: LIMIT)
          text = value.to_s
          BROADCASTS.each { |escape, literal| text = text.gsub(escape, literal) }
          text = text.gsub(SUBTEAM) { "@#{::Regexp.last_match(1).to_s.delete_prefix('@')}" }
          truncate(text, limit)
        end

        # True when the text would have pinged a channel before we neutralized it.
        # Kept as a question rather than a side effect so a card can *say so*.
        def broadcast?(value)
          text = value.to_s
          BROADCASTS.each_key.any? { |escape| text.include?(escape) } || text.match?(SUBTEAM)
        end

        private

        def truncate(text, limit)
          return text if text.length <= limit

          "#{text[0, limit - 1]}…"
        end
      end
    end
  end
end
