require "test_helper"

module Concierge
  # The deprecation "dreaming" job (design §10.2). Nothing in the write path ever
  # removes a rule, so a weekly pass proposes consolidations and retirements —
  # with evidence — and stops there. It must be able to *propose* and unable to
  # *act*, and it must be quiet on the second run.
  class RuleDreamingJobTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
      @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    end

    test "a rule injected into runs and never once cited is proposed for retirement" do
      rule = activate(@csm, "Never quote a delivery date.", activated_at: 30.days.ago)
      inject_into_runs(rule, times: 6, citing: false)

      RuleDreamingJob.perform_now

      assert rule.reload.retirement_proposed?
      assert_equal "never cited", rule.deprecation_evidence["reason"]
      assert_equal 6, rule.deprecation_evidence["runs_injected"]
      # ...and it is still in force. Only a human retires it.
      assert rule.active?
      assert_includes Rules.active_for(@csm).map(&:id), rule.id
    end

    test "a rule the agent has cited is left alone" do
      rule = activate(@csm, "Never quote a delivery date.", activated_at: 30.days.ago)
      inject_into_runs(rule, times: 6, citing: true)

      RuleDreamingJob.perform_now

      refute rule.reload.retirement_proposed?
    end

    test "a rule with too small a sample is left alone" do
      rule = activate(@csm, "Never quote a delivery date.", activated_at: 30.days.ago)
      inject_into_runs(rule, times: 2, citing: false)

      RuleDreamingJob.perform_now

      refute rule.reload.retirement_proposed?, "two quiet runs is not evidence"
    end

    test "a rule approved yesterday is never up for retirement today" do
      rule = activate(@csm, "Never quote a delivery date.", activated_at: 1.day.ago)
      inject_into_runs(rule, times: 20, citing: false)

      RuleDreamingJob.perform_now

      refute rule.reload.retirement_proposed?
    end

    test "an active rule that already points at its replacement is proposed for retirement" do
      old         = activate(@csm, "Never quote a delivery date.")
      replacement = activate(@csm, "Check the shipping API before any date.")
      old.update_column(:superseded_by_id, replacement.id)

      RuleDreamingJob.perform_now

      assert old.reload.retirement_proposed?
      assert_equal "superseded", old.deprecation_evidence["reason"]
    end

    test "two active rules that say the same thing become one merge proposal" do
      first  = activate(@csm, "Always attach the invoice PDF to billing emails.")
      second = activate(@csm, "Always attach the invoice PDF to the billing emails.",
                        acknowledge: true)

      RuleDreamingJob.perform_now

      merge = AgentRule.proposed.sole
      assert_equal [ first.id, second.id ], merge.merges
      assert_equal "dreaming", merge.provenance["source"]
      assert_equal 2, merge.provenance["evidence"].size
      # Both originals are still in force until a human approves the merge.
      assert first.reload.active?
      assert second.reload.active?
    end

    test "approving a merge proposal retires what it replaced, with the trail" do
      first  = activate(@csm, "Always attach the invoice PDF to billing emails.")
      second = activate(@csm, "Always attach the invoice PDF to the billing emails.",
                        acknowledge: true)
      RuleDreamingJob.perform_now
      merge = AgentRule.proposed.sole

      Rules.activate!(merge, by: "sam@acme.test", acknowledge_conflicts: true)
      merge.merges.each do |id|
        Rules.deprecate!(AgentRule.find(id), by: "sam@acme.test", superseded_by: merge)
      end

      assert merge.reload.active?
      assert_equal [ merge.id, merge.id ],
                   [ first.reload.superseded_by_id, second.reload.superseded_by_id ]
      assert_equal [ merge.id ], Rules.active_for(@csm).map(&:id)
    end

    test "the merged rule sits in the broadest bucket of the set it replaces" do
      wide = Rules.propose(@csm, body: "Always attach the invoice PDF.", applies_to: :agent,
                           author: "a")
      Rules.activate!(wide, by: "sam@acme.test")
      narrow = Rules.propose(@csm, body: "Always attach the invoice PDF here.", author: "a")
      Rules.activate!(narrow, by: "sam@acme.test", acknowledge_conflicts: true)

      RuleDreamingJob.perform_now

      merge = AgentRule.proposed.sole
      assert_nil merge.subject_id, "consolidating a blanket rule must leave a blanket rule"
    end

    test "unrelated rules are not proposed for merging" do
      activate(@csm, "Always attach the invoice PDF.")
      activate(@csm, "Greet them by their first name.")

      RuleDreamingJob.perform_now

      assert_equal 0, AgentRule.proposed.count
    end

    test "duplicates across the agent boundary are not duplicates" do
      activate(@csm, "Always attach the invoice PDF to billing emails.")
      activate(@billing, "Always attach the invoice PDF to billing emails.")

      RuleDreamingJob.perform_now

      assert_equal 0, AgentRule.proposed.count, "the dreaming job merged across agents"
    end

    test "a second weekly pass proposes nothing new" do
      activate(@csm, "Always attach the invoice PDF to billing emails.")
      activate(@csm, "Always attach the invoice PDF to the billing emails.", acknowledge: true)
      stale = activate(@csm, "Greet them by their first name.", activated_at: 30.days.ago)
      inject_into_runs(stale, times: 6, citing: false)

      RuleDreamingJob.perform_now
      before = [ AgentRule.count, AgentRule.retirement_proposed.count ]
      RuleDreamingJob.perform_now

      assert_equal before, [ AgentRule.count, AgentRule.retirement_proposed.count ]
    end

    test "the job cannot activate, retire or edit anything on its own" do
      rule = activate(@csm, "Never quote a delivery date.", activated_at: 30.days.ago)
      inject_into_runs(rule, times: 6, citing: false)

      RuleDreamingJob.perform_now

      assert_equal %w[active], AgentRule.where(state: %w[active deprecated]).pluck(:state).uniq
      assert_equal 1, rule.reload.version, "the dreaming job rewrote a rule"
    end

    private

    def activate(scope, body, activated_at: nil, acknowledge: false)
      rule = Rules.propose(scope, body: body, author: "drafter@acme.test")
      Rules.activate!(rule, by: "sam@acme.test", acknowledge_conflicts: acknowledge)
      rule.update_column(:activated_at, activated_at) if activated_at
      rule
    end

    # Provenance rows that had this rule in the prompt — with or without the agent
    # claiming it applied. This is what makes "never cited" checkable at all.
    def inject_into_runs(rule, times:, citing:)
      times.times do
        AgentRun.create!(
          **@csm.key, trigger: "reactive", status: "ok", model: "m",
          rules: [ rule.pin ], rule_ids_applied: citing ? [ rule.id ] : []
        )
      end
    end
  end
end
