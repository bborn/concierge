module Concierge
  module Slack
    # Posts a proposal's approval card (design §10.7's outbound half). Wired as
    # `config.proposal_notifier`, so it runs when a proposal is created and is the
    # only place in this seam that talks *to* Slack about a new decision.
    #
    #   c.proposal_notifier = Concierge::Slack::Notifier
    #
    # Two anti-noise rules live here, because this is the only chokepoint every
    # card passes through (§2.6):
    #
    #   * **A per-agent daily card cap.** Over it, the card is not posted — a
    #     business function cannot make a channel unreadable. The proposal is
    #     untouched and still in the queue, and the suppression is *recorded* so
    #     the digest can say "and 14 more" rather than the operator finding out by
    #     accident.
    #   * **One thread per case.** The first card for an (agent, account) pair
    #     starts a thread; every later card replies into it. A channel is then a
    #     list of accounts, not a firehose of individual actions.
    #
    # It never raises. Not for the usual channel reason — this is not a delivery
    # path — but because a notifier that could raise would make posting a card able
    # to fail *proposing* one, and then Slack being down would cost authority
    # instead of convenience. Every failure is written to a SlackCard row instead.
    class Notifier
      def self.call(proposal)
        new(proposal).call
      end

      def initialize(proposal)
        @proposal = proposal
      end

      def call
        return unless postable?

        scope = Concierge::Scope.resolve(agent_slug: proposal.agent_slug,
                                         subject_id: proposal.subject_id)
        return record_failure("the (agent, account) pair on this proposal no longer resolves") unless scope

        channel = Concierge::Slack.channel_for(scope.agent_slug)
        return log("#{scope.agent_slug} has no Slack channel configured") unless channel

        return suppress(channel) if at_daily_cap?(scope)

        post(scope, channel)
      rescue StandardError => e
        record_failure("#{e.class}: #{e.message}")
      end

      private

      attr_reader :proposal

      def postable?
        settings = Concierge::Slack.settings
        return log("Slack is not configured") unless settings.configured?
        return log("Slack has no bot token or transport, so no card can be posted") unless settings.can_post?
        # One card per proposal. Proposing is idempotent by key (§10.6); posting
        # has to be too, or a retried job puts a second Approve button on the same
        # row.
        return log("proposal #{proposal.id} already has a Slack card") if card_exists?

        true
      end

      def card_exists?
        SlackCard.exists?(agent_proposal_id: proposal.id)
      end

      def at_daily_cap?(scope)
        cap = Concierge::Slack.settings.daily_card_cap
        return false unless cap

        SlackCard.posted_today(scope.agent_slug).count >= cap
      end

      def post(scope, channel)
        card     = Card.new(proposal)
        thread   = SlackCard.thread_ts_for(scope)
        response = client.post_message(channel: channel, blocks: card.blocks,
                                       text: card.text, thread_ts: thread)

        create!(scope, state: "posted", channel_id: response["channel"] || channel,
                       message_ts: response["ts"], thread_ts: thread || response["ts"],
                       posted_at: Time.current)
      end

      # Over the cap. Recorded rather than dropped: "we deliberately did not tell
      # you about this one" is information an operator is owed, and the digest
      # reads these rows.
      def suppress(_channel)
        scope = Concierge::Scope.resolve(agent_slug: proposal.agent_slug,
                                         subject_id: proposal.subject_id)
        Concierge.logger&.info(
          "[concierge] #{proposal.agent_slug} is at its daily Slack card cap; " \
          "proposal #{proposal.id} was not posted (it is still in the approval queue)"
        )
        create!(scope, state: "suppressed")
      end

      def record_failure(message)
        Concierge.logger&.warn(
          "[concierge] could not post a Slack card for proposal #{proposal.id}: #{message}"
        )
        SlackCard.create!(
          agent_slug: proposal.agent_slug, subject_type: proposal.subject_type,
          subject_id: proposal.subject_id, agent_proposal_id: proposal.id,
          state: "failed", error: message
        )
      rescue StandardError => e
        # The row is a courtesy; losing it must not be able to raise into
        # Proposal.propose either.
        Concierge.logger&.error("[concierge] could not even record the Slack failure: #{e.message}")
        nil
      end

      def create!(scope, **attributes)
        keys = scope ? scope.key : { agent_slug: proposal.agent_slug,
                                     subject_type: proposal.subject_type,
                                     subject_id: proposal.subject_id }
        SlackCard.create!(**keys, agent_proposal_id: proposal.id, **attributes)
      end

      def client
        @client ||= Client.new
      end

      def log(message)
        Concierge.logger&.debug("[concierge] slack notifier skipped: #{message}")
        nil
      end
    end
  end
end
