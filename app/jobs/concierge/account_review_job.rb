module Concierge
  # Runs one proactive review of a single account by a single agent and delivers
  # the outcome, accounting the token spend and marking that (agent, account)
  # reviewed. The agent travels as its slug, not as an object, because job
  # arguments have to serialize; it is resolved from config on the far side.
  class AccountReviewJob < ApplicationJob
    queue_as :default

    def perform(subject_id, instruction:, channel: nil, agent: Configuration::DEFAULT_AGENT_SLUG)
      agent = Concierge.config.agent(agent)
      return unless agent

      subject = Concierge.config.account.find_subject(subject_id)
      scope   = Concierge::Scope.new(agent, subject)

      result = Concierge::Run.proactive(scope, instruction: instruction)
      return unless result.ok?

      Concierge::Budget.new.spend!(scope, result.total_tokens)
      Concierge::Outreach.deliver(result, scope, channel: channel)
      Concierge::ChangeDetector.mark_reviewed!(scope)
    end
  end
end
