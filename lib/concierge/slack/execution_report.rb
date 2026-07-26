module Concierge
  module Slack
    # Step 6 of the split handler order: once ProposalExecutionJob has run the
    # executor, tell Slack what actually happened.
    #
    # It exists as its own class rather than as more of Intake because it runs in a
    # *different process* from the click. There is no interactivity payload here
    # and no response body to return — the person who clicked has long since had
    # their 200 — so both channels back to them are outbound calls:
    #
    #   * the card is redrawn from the row, which is now either executed or
    #     approved-and-refused;
    #   * a refusal is also whispered to whoever clicked, because a card quietly
    #     changing from "queued" to "not performed" is not something a human who
    #     walked away from Slack will ever see.
    #
    # Both are best-effort and neither may raise. The execution is already durable;
    # a Slack call that failed afterwards must not fail the job, because a retried
    # job would re-enter Proposal::Execute for an action a human approved once.
    class ExecutionReport
      # +:already_executed+ is here too: it means the action was performed, just
      # not by this attempt. Reporting it as a refusal would tell an operator to go
      # chase something that is done.
      PERFORMED = %i[executed already_executed].freeze

      def self.call(proposal, outcome, channel: nil, ts: nil, user: nil)
        new(proposal, outcome, channel: channel, ts: ts, user: user).call
      end

      # The one sentence an operator needs when an approval did not become an
      # action. Shared with Intake so the wording cannot drift between the surface
      # that refuses synchronously and the job that refuses later.
      def self.refusal_message(proposal, outcome)
        "Proposal ##{proposal.id} was approved but not performed " \
        "(#{outcome.to_s.tr('_', ' ')})#{": #{proposal.execution_error}" if proposal.execution_error}. " \
        "It is waiting in /concierge/admin/proposals."
      end

      def initialize(proposal, outcome, channel: nil, ts: nil, user: nil)
        @proposal = proposal
        @outcome  = outcome
        @channel  = channel
        @ts       = ts
        @user     = user
      end

      def call
        refresh_card
        whisper_refusal unless PERFORMED.include?(outcome)
        nil
      end

      private

      attr_reader :proposal, :outcome, :channel, :ts, :user

      def refresh_card
        return if channel.blank? || ts.blank?

        card = Card.new(proposal)
        Client.new.update_message(channel: channel, ts: ts, blocks: card.decided_blocks,
                                  text: card.text)
      rescue StandardError => e
        # Same trade as the synchronous redraw: Postgres is the record and a stale
        # card is recoverable. Raising here would retry a job whose execution
        # already happened.
        Concierge.logger&.warn(
          "[concierge] proposal #{proposal.id} was performed but its Slack card could not be " \
          "updated: #{e.class}: #{e.message}"
        )
      end

      def whisper_refusal
        message = self.class.refusal_message(proposal, outcome)
        return log_nowhere(message) if channel.blank? || user.blank?

        Client.new.post_ephemeral(channel: channel, user: user, text: message)
      rescue StandardError => e
        Concierge.logger&.warn("[concierge] could not deliver a Slack refusal: #{e.message}")
      end

      def log_nowhere(message)
        Concierge.logger&.info("[concierge] slack refusal (nowhere to show it): #{message}")
      end
    end
  end
end
