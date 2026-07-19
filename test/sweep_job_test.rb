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

    test "priority orders high-value accounts first" do
      big = Tenant.create!(name: "Enterprise", plan: "enterprise")
      small = Tenant.create!(name: "Small", plan: "pro")
      subjects = [ Concierge.config.account.build(small), Concierge.config.account.build(big) ]

      ordered = Concierge::PriorityService.order(subjects).map { |s| s.to_model }
      assert_equal big, ordered.first
    end
  end
end
