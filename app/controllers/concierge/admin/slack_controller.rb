module Concierge
  module Admin
    # The Slack side of the approval queue, in the surface that does not depend on
    # Slack (design §10.7). Two questions this screen exists to answer:
    #
    #   * **Is the remote control actually working?** Which agent posts to which
    #     channel, how many cards went out today against the cap, and which cards
    #     failed to post — a card that never appeared is otherwise invisible, and
    #     an operator would conclude the agent had nothing to say.
    #   * **What is Slack not telling us?** Suppressed cards (over the daily cap)
    #     and failed ones both leave proposals waiting in
    #     /concierge/admin/proposals. This screen is where that becomes obvious
    #     rather than something you find out by scrolling a channel.
    #
    # Read-only on purpose. Decisions belong on the proposals screen and in Slack;
    # a third place to click Approve would be a third place for two people to think
    # they were the decider.
    class SlackController < BaseController
      def index
        @settings = Concierge.config.slack
        @agents   = Concierge.config.agents
        @cards    = Concierge::SlackCard.recent.limit(50)

        @posted_today = Concierge::SlackCard.posted_since(Time.current.beginning_of_day)
                                            .group(:agent_slug).count
        @suppressed   = Concierge::SlackCard.suppressed.group(:agent_slug).count
        @failed       = Concierge::SlackCard.failed.group(:agent_slug).count
        @awaiting     = Concierge::AgentProposal.proposed.group(:agent_slug).count
      end
    end
  end
end
