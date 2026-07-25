module Concierge
  # The one static recurring job (registered once in the host's recurring.yml).
  # It enqueues per-(agent, account) reviews for due routines, in priority order,
  # skipping scopes that haven't changed or whose budget is spent. No per-account
  # cron (design §3.6).
  class SweepJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      budget = Concierge::Budget.new
      candidates = Concierge::PriorityService.order(due_routines(now)) { |c| c[:scope].subject }

      candidates.each do |candidate|
        scope = candidate[:scope]
        next unless Concierge::ChangeDetector.changed?(scope)
        next if budget.exhausted?(scope)

        Concierge::AccountReviewJob.perform_later(
          scope.subject.id,
          agent: scope.agent_slug,
          instruction: candidate[:instruction],
          channel: candidate[:channel]
        )
        candidate[:record]&.advance!(now)
      end
    end

    private

    # Due author-created routines, each under the agent that owns it, plus the
    # code-declared weekly review (v1 ships one built-in routine; routines-as-data
    # is the seam).
    def due_routines(now)
      rows = Concierge::Routine.due(now).filter_map do |routine|
        agent = Concierge.config.agent(routine.agent_slug)
        # A routine whose agent was removed from config — or switched off at the
        # kill switch — is inert data, not an error (step-0 spike §A1).
        next unless agent&.enabled?

        subject = Concierge.config.account.find_subject(routine.subject_id)
        { scope: Concierge::Scope.new(agent, subject), instruction: routine.instruction,
          channel: routine.channel, record: routine }
      end

      rows + weekly_reviews(rows)
    end

    # The weekly review is declared at the *top level* of the config, so it
    # belongs to the top-level agent — the default +:csm+ — rather than firing
    # once per business function against the same account. A host that wants its
    # billing agent reviewing weekly gives it a routine row.
    def weekly_reviews(existing)
      return [] unless Concierge.config.weekly_review_enabled

      agent = Concierge.config.agent
      return [] unless agent&.enabled?

      already = existing.select { |row| row[:scope].agent_slug == agent.memory_namespace }
                        .map { |row| row[:scope].subject.id }

      Concierge.config.account.each_subject.filter_map do |subject|
        next if already.include?(subject.id)

        { scope: Concierge::Scope.new(agent, subject),
          instruction: Concierge.config.weekly_review_instruction, channel: nil, record: nil }
      end
    end
  end
end
