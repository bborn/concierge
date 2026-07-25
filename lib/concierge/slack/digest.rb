module Concierge
  module Slack
    # The other half of anti-noise (§2.6): **digests for unilateral work.**
    #
    # An agent that is `:autonomous` on an action class does not propose — it acts.
    # Posting a card for each of those would be a notification nobody can act on,
    # and a channel that cries wolf is a channel where the refund card gets
    # scrolled past. So autonomous work arrives as one periodic summary per agent
    # instead: what it did, to whom, and what it is still waiting on a human for.
    #
    #   Concierge::Slack::Digest.deliver_all(since: 24.hours.ago)
    #
    # Nothing to report means nothing is posted. A daily "0 things happened" is
    # exactly the noise this exists to remove.
    class Digest
      def self.deliver_all(since: 24.hours.ago, now: Time.current)
        Concierge::Slack.settings.channels.keys.filter_map do |agent_slug|
          deliver(agent_slug, since: since, now: now)
        end
      end

      def self.deliver(agent_slug, since: 24.hours.ago, now: Time.current)
        new(agent_slug, since: since, now: now).deliver
      end

      def initialize(agent_slug, since:, now: Time.current)
        @agent_slug = agent_slug.to_s
        @since      = since
        @now        = now
      end

      def deliver
        return unless Concierge::Slack.settings.can_post?

        channel = Concierge::Slack.channel_for(agent_slug)
        return unless channel

        lines = summary_lines
        return if lines.empty?

        Client.new.post_message(channel: channel, blocks: blocks(lines), text: headline)
      rescue StandardError => e
        # A digest is a courtesy. It must not be able to fail the recurring job that
        # also sweeps routines and expires proposals.
        Concierge.logger&.warn("[concierge] slack digest for #{agent_slug} failed: #{e.class}: #{e.message}")
        nil
      end

      # What went out without anyone being asked, plus what is still waiting.
      def summary_lines
        lines = []

        deliveries.group_by(&:subject_id).each do |subject_id, rows|
          # By channel, not by kind: "3× email" is what an operator can act on, and
          # nearly every row's kind is "outreach" anyway.
          channels = rows.group_by(&:channel).transform_values(&:size)
                         .map { |channel, count| count > 1 ? "#{count}× #{channel}" : channel }
          lines << "• *#{rows.first.subject_type} ##{subject_id}* — #{channels.join(', ')}"
        end

        lines << "• #{pluralize(runs, 'run')} with no message sent" if runs.positive? && deliveries.empty?
        lines << "• :hourglass: *#{pluralize(awaiting, 'proposal')} still waiting on a human* " \
                 "— `/concierge/admin/proposals`" if awaiting.positive?
        lines << "• :mute: #{pluralize(suppressed, 'card')} #{suppressed == 1 ? 'was' : 'were'} " \
                 "not posted here (daily cap) — they are in the queue" if suppressed.positive?
        lines
      end

      private

      attr_reader :agent_slug, :since, :now

      def headline
        "#{agent_slug}: #{pluralize(deliveries.size, 'message')} sent on its own authority"
      end

      def pluralize(count, noun)
        "#{count} #{noun}#{'s' if count != 1}"
      end

      def blocks(lines)
        [
          { type: "section", text: { type: "mrkdwn", text: "*#{headline}*" } },
          { type: "section", text: { type: "mrkdwn", text: Text.safe(lines.join("\n")) } },
          { type: "context",
            elements: [ { type: "mrkdwn",
                          text: "Autonomous work since #{since.strftime('%b %-d %H:%M')} — " \
                                "summarised, not carded, on purpose." } ] }
        ]
      end

      # Autonomous sends only. A delivery that came from an approved proposal
      # already had a card, and reporting it again as unilateral would be a lie
      # about who decided it.
      #
      # Deliberately agent-wide and account-spanning: a digest is one agent
      # reporting on its own week to its own channel, which is the same shape the
      # admin screens have. The agent dimension is never crossed — a channel
      # belongs to one business function, and a row from another agent landing in
      # it would be the disclosure bug §10.12 is about.
      def deliveries
        @deliveries ||= begin
          rows = ChannelDelivery.where(agent_slug: agent_slug, created_at: since..now).to_a
          approved = AgentProposal.where(agent_slug: agent_slug, executed_at: since..now)
                                  .pluck(:subject_type, :subject_id).to_set
          rows.reject { |row| approved.include?([ row.subject_type, row.subject_id ]) }
        end
      end

      def runs
        @runs ||= AgentRun.where(agent_slug: agent_slug, created_at: since..now).count
      end

      def awaiting
        @awaiting ||= AgentProposal.where(agent_slug: agent_slug).proposed.count
      end

      def suppressed
        @suppressed ||= SlackCard.where(agent_slug: agent_slug, created_at: since..now)
                                 .suppressed.count
      end
    end
  end
end
