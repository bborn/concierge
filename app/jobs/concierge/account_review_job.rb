module Concierge
  # Runs one proactive review for a single account and delivers the outcome,
  # accounting the token spend and marking the account reviewed.
  class AccountReviewJob < ApplicationJob
    queue_as :default

    def perform(subject_id, instruction:, channel: nil)
      subject = Concierge.config.account.find_subject(subject_id)

      result = Concierge::Run.proactive(subject, instruction: instruction)
      return unless result.ok?

      Concierge::Budget.new.spend!(subject, result.total_tokens)
      Concierge::Outreach.deliver(result, subject, channel: channel)
      Concierge::ChangeDetector.mark_reviewed!(subject)
    end
  end
end
