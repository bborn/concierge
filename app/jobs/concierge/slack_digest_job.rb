module Concierge
  # Posts each agent's digest of unilateral work (§2.6). A host schedules this on
  # whatever cadence its operators want to hear from their agents — daily is the
  # obvious one:
  #
  #   # config/recurring.yml
  #   concierge_slack_digest:
  #     class: Concierge::SlackDigestJob
  #     schedule: every day at 9am
  #
  # Deliberately *not* folded into SweepJob. The sweep runs often (it has to, to
  # catch due routines), and a digest that posted on the sweep's cadence would be
  # the noise it exists to prevent.
  class SlackDigestJob < ApplicationJob
    queue_as :default

    def perform(since: nil, now: Time.current)
      Concierge::Slack::Digest.deliver_all(since: since || (now - 24.hours), now: now)
    end
  end
end
