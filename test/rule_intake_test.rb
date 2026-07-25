require "test_helper"

module Concierge
  # The write path end to end (design §10.2): a human correction is stored
  # verbatim, an out-of-band job generalizes it into a rule, and the rule waits.
  #
  #   correction -> verbatim memory -> generalizer job -> proposed rule -> human tap
  #
  # The invariant under test at every step: nothing on this path can make a rule
  # active. Only a person can.
  class RuleIntakeTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @scope   = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    end

    # --- routing -------------------------------------------------------------

    test "a relationship fact is memory only — no rule pipeline" do
      intake = nil
      assert_no_enqueued_jobs only: RuleGeneralizerJob do
        intake = Learning.capture(@scope, content: "Their renewal is in March.")
      end

      assert_equal :fact, intake.route
      refute intake.rule_pending?
      assert_equal "human", intake.memory.source
      assert_equal 0, AgentRule.count
    end

    test "a behavioral correction is stored verbatim AND queued for generalization" do
      intake = nil
      assert_enqueued_jobs 1, only: RuleGeneralizerJob do
        intake = Learning.capture(
          @scope,
          content: "Never quote a delivery date without checking the shipping API first."
        )
      end

      assert_equal :rule, intake.route
      assert intake.rule_pending?
      # The verbatim correction is still memory: it is the evidence for the rule,
      # and it still steers the next prompt whether or not the rule is approved.
      assert_equal "Never quote a delivery date without checking the shipping API first.",
                   intake.memory.body
      assert intake.memory.pinned
    end

    test "an explicit operator choice beats the heuristic in both directions" do
      assert_enqueued_jobs 1, only: RuleGeneralizerJob do
        Learning.capture(@scope, content: "Their renewal is in March.", kind: :rule)
      end

      assert_no_enqueued_jobs only: RuleGeneralizerJob do
        Learning.capture(@scope, content: "Never quote a delivery date.", kind: :fact)
      end
    end

    test "blank content is still ignored" do
      assert_nil Learning.capture(@scope, content: "   ")
      assert_equal 0, Memory.for_scope(@scope).count
    end

    # --- the generalizer job -------------------------------------------------

    test "the job drafts a proposed rule with the correction as its provenance" do
      perform_enqueued_jobs do
        Learning.capture(@scope, content: "operator: Never quote a delivery date. Dana asked twice.",
                         author: "sam@acme.test")
      end

      rule = AgentRule.sole
      assert rule.proposed?, "the generalizer promoted a rule without a human"
      assert_equal "csm", rule.agent_slug
      assert_equal "Never quote a delivery date.", rule.body
      assert_equal "human_correction", rule.provenance["source"]
      assert_equal "sam@acme.test", rule.provenance["corrected_by"]
      assert_equal "operator: Never quote a delivery date. Dana asked twice.",
                   rule.provenance["verbatim"]
    end

    test "the job authors as the agent, which structurally cannot approve" do
      perform_enqueued_jobs do
        Learning.capture(@scope, content: "Never quote a delivery date.")
      end

      rule = AgentRule.sole
      assert_equal Rules.agent_actor("csm"), rule.author
      assert_raises(Rules::GateError) { Rules.activate!(rule, by: rule.author) }
    end

    test "the drafted rule lands in the namespace of the agent that was corrected" do
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

      perform_enqueued_jobs do
        Learning.capture(billing, content: "Always attach the invoice PDF.")
      end

      assert_equal "billing", AgentRule.sole.agent_slug
      assert_empty Rules.active_for(@scope)
    end

    test "the drafted rule is conflict-checked against what is already in force" do
      existing = Rules.propose(@scope, body: "Always attach the invoice PDF to billing emails.",
                               author: "a")
      Rules.activate!(existing, by: "sam@acme.test")

      perform_enqueued_jobs do
        Learning.capture(@scope, content: "Never attach the invoice PDF to billing emails.")
      end

      drafted = AgentRule.proposed.sole
      assert_equal "contradiction", drafted.conflicts.first["kind"]
      assert_equal existing.id, drafted.conflicts.first["rule_id"]
    end

    test "a host generalizer replaces the default draft, and still cannot activate" do
      Concierge.config.rule_generalizer = lambda do |correction|
        { "body" => "Check the shipping API first.", "enforcement" => "advisory" }
      end

      perform_enqueued_jobs do
        Learning.capture(@scope, content: "Never quote a delivery date, you got it wrong again.")
      end

      rule = AgentRule.sole
      assert_equal "Check the shipping API first.", rule.body
      assert rule.proposed?
    end

    test "one correction produces one proposal, however many times the job runs" do
      # Found by driving the running app: ActiveJob delivery is at-least-once, so a
      # retry after the propose succeeded posted a second identical card. An
      # operator staring at two copies of one instruction cannot tell which to
      # approve, and approving both is how a rule set starts to rot.
      intake = Learning.capture(@scope, content: "Never mention our roadmap dates.")

      3.times { RuleGeneralizerJob.perform_now(intake.memory.id) }

      assert_equal 1, AgentRule.count
    end

    test "a rejected proposal does not come back on a retry" do
      intake = Learning.capture(@scope, content: "Never mention our roadmap dates.")
      RuleGeneralizerJob.perform_now(intake.memory.id)
      Rules.reject!(AgentRule.sole, by: "sam@acme.test", reason: "too broad")

      RuleGeneralizerJob.perform_now(intake.memory.id)

      assert_equal 1, AgentRule.count
      assert_equal "rejected", AgentRule.sole.state
    end

    test "a correction for an agent that no longer exists is inert, not an error" do
      memory = ContextStore.new.remember(@scope, body: "Never quote a date.", source: :human)
      memory.update_column(:agent_slug, "retired_agent")

      assert_nothing_raised { RuleGeneralizerJob.perform_now(memory.id) }
      assert_equal 0, AgentRule.count
    end

    test "a correction whose memory has been deleted is inert" do
      assert_nothing_raised { RuleGeneralizerJob.perform_now(-1) }
    end

    test "a correction that generalizes to nothing proposes nothing" do
      Concierge.config.rule_generalizer = ->(_correction) { "   " }

      perform_enqueued_jobs do
        Learning.capture(@scope, content: "Never quote a delivery date.")
      end

      assert_equal 0, AgentRule.count
    end

    # --- the heuristic itself ------------------------------------------------

    test "the heuristic reads instructions as instructions and facts as facts" do
      instructions = [
        "Never promise a delivery date.",
        "Always cc their account manager.",
        "Don't send anything before 9am their time.",
        "From now on, use their legal entity name on invoices.",
        "Make sure the DPA is attached.",
        "Stop offering the free trial extension.",
        "You should check the shipping API first."
      ]
      facts = [
        "Their renewal is in March.",
        "Dana is the champion here; the CEO is skeptical.",
        "They pay by wire, net-30.",
        "Procurement wants SOC 2 docs."
      ]

      instructions.each do |text|
        assert Rules::Generalizer.behavioral?(text), "#{text.inspect} should read as a rule"
      end
      facts.each do |text|
        refute Rules::Generalizer.behavioral?(text), "#{text.inspect} should read as a fact"
      end
    end

    test "the default draft keeps one concern and strips the operator's framing" do
      drafted = Rules::Generalizer.call(
        "FYI: Never quote a delivery date without checking. Dana got burned by this in May."
      )

      assert_equal "Never quote a delivery date without checking.", drafted["body"]
      assert_equal "advisory", drafted["enforcement"]
    end
  end
end
