module Concierge
  # The one static recurring job (registered once in the host's recurring.yml).
  # It enqueues per-account reviews for due routines, in priority order, skipping
  # accounts that haven't changed or whose budget is spent. No per-account cron
  # (design §3.6).
  class SweepJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      budget = Concierge::Budget.new
      candidates = Concierge::PriorityService.order(due_routines(now)) { |c| c[:subject] }

      candidates.each do |candidate|
        subject = candidate[:subject]
        next unless Concierge::ChangeDetector.changed?(subject)
        next if budget.exhausted?(subject)

        Concierge::AccountReviewJob.perform_later(
          subject.id,
          instruction: candidate[:instruction],
          channel: candidate[:channel]
        )
        candidate[:record]&.advance!(now)
      end
    end

    private

    # Due author-created routines, plus the code-declared weekly review for every
    # account (v1 ships one built-in routine; routines-as-data is the seam).
    def due_routines(now)
      rows = Concierge::Routine.due(now).map do |routine|
        subject = Concierge.config.account.find_subject(routine.subject_id)
        { subject: subject, instruction: routine.instruction, channel: routine.channel, record: routine }
      end

      rows + weekly_reviews(rows.map { |r| r[:subject].id })
    end

    def weekly_reviews(already)
      return [] unless Concierge.config.weekly_review_enabled

      Concierge.config.account.each_subject.filter_map do |subject|
        next if already.include?(subject.id)

        { subject: subject, instruction: Concierge.config.weekly_review_instruction, channel: nil, record: nil }
      end
    end
  end
end
