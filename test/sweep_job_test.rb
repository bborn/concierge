require "test_helper"

module Concierge
  class SweepJobTest < ActiveJob::TestCase
    setup do
      Concierge.config.weekly_review_enabled = false # isolate routine behavior
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
      @subject = Concierge.config.account.build(@tenant)
    end

    test "a due routine enqueues an AccountReviewJob; a not-due one does not" do
      Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                      schedule: "0 9 * * 1", instruction: "due one", next_run_at: 1.hour.ago)
      Tenant.create!(name: "Later").tap do |t|
        Routine.create!(subject_type: "account", subject_id: t.id.to_s,
                        schedule: "0 9 * * 1", instruction: "later", next_run_at: 1.hour.from_now)
      end

      assert_enqueued_jobs 1, only: Concierge::AccountReviewJob do
        Concierge::SweepJob.perform_now
      end
    end

    test "the change-detector gate skips an unchanged account" do
      Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                      schedule: "0 9 * * 1", instruction: "x", next_run_at: 1.hour.ago)
      # Mark the account as already reviewed at its current snapshot.
      ChangeDetector.mark_reviewed!(@subject)

      assert_no_enqueued_jobs only: Concierge::AccountReviewJob do
        Concierge::SweepJob.perform_now
      end
    end

    test "budget exhaustion halts further runs" do
      Concierge.config.budget = { per_tenant: 1, global: 1 }
      Concierge::Budget.new.spend!(@subject, 100) # exhaust
      Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                      schedule: "0 9 * * 1", instruction: "x", next_run_at: 1.hour.ago)

      assert_no_enqueued_jobs only: Concierge::AccountReviewJob do
        Concierge::SweepJob.perform_now
      end
    end

    test "a routine sweeps under the agent that owns it" do
      Concierge::Test.configure_agents!
      Routine.create!(agent_slug: "billing", subject_type: "account", subject_id: @tenant.id.to_s,
                      schedule: "0 9 * * 1", instruction: "invoice day", next_run_at: 1.hour.ago)

      Concierge::SweepJob.perform_now

      job = enqueued_jobs.find { |j| j[:job] == Concierge::AccountReviewJob }
      assert_equal "billing", job[:args].last["agent"]
    end

    test "a routine whose agent is switched off does not sweep" do
      Concierge::Test.configure_agents!
      Concierge.configure { |c| c.agent(:billing) { enabled false } }
      Routine.create!(agent_slug: "billing", subject_type: "account", subject_id: @tenant.id.to_s,
                      schedule: "0 9 * * 1", instruction: "invoice day", next_run_at: 1.hour.ago)

      assert_no_enqueued_jobs only: Concierge::AccountReviewJob do
        Concierge::SweepJob.perform_now
      end
    end

    test "a routine pointing at an agent no host declares is inert, not an error" do
      Routine.create!(agent_slug: "retired", subject_type: "account", subject_id: @tenant.id.to_s,
                      schedule: "0 9 * * 1", instruction: "orphan", next_run_at: 1.hour.ago)

      assert_no_enqueued_jobs only: Concierge::AccountReviewJob do
        assert_nothing_raised { Concierge::SweepJob.perform_now }
      end
    end

    test "the change gate is per (agent, account), so one agent's review does not skip another's" do
      Concierge::Test.configure_agents!
      [ "csm", "billing" ].each do |slug|
        Routine.create!(agent_slug: slug, subject_type: "account", subject_id: @tenant.id.to_s,
                        schedule: "0 9 * * 1", instruction: "x", next_run_at: 1.hour.ago)
      end
      ChangeDetector.mark_reviewed!(Scope.new(Concierge.config.agent(:csm), @subject))

      Concierge::SweepJob.perform_now

      slugs = enqueued_jobs.select { |j| j[:job] == Concierge::AccountReviewJob }
                           .map { |j| j[:args].last["agent"] }
      assert_equal [ "billing" ], slugs
    end

    test "the top-level weekly review belongs to the default agent, not to every agent" do
      Concierge::Test.configure_agents!
      Concierge.config.weekly_review_enabled = true

      Concierge::SweepJob.perform_now

      slugs = enqueued_jobs.select { |j| j[:job] == Concierge::AccountReviewJob }
                           .map { |j| j[:args].last["agent"] }
      assert_equal [ "csm" ], slugs.uniq
    end

    test "priority orders high-value accounts first" do
      big = Tenant.create!(name: "Enterprise", plan: "enterprise")
      small = Tenant.create!(name: "Small", plan: "pro")
      subjects = [ Concierge.config.account.build(small), Concierge.config.account.build(big) ]

      ordered = Concierge::PriorityService.order(subjects).map { |s| s.to_model }
      assert_equal big, ordered.first
    end
  end
end
