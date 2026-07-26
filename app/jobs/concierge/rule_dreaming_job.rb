module Concierge
  # The deprecation "dreaming" job (design §10.2). Rules accrete; nothing in the
  # write path ever removes one. Weekly, this looks over each agent's active rule
  # set and *proposes* consolidations and retirements — with the evidence attached
  # — and stops there. Every proposal waits for a human, exactly like every other
  # rule transition.
  #
  # Three kinds of evidence, all cheap and all checkable:
  #
  #   never cited    the rule has been injected into N runs and the agent has
  #                  never once claimed to apply it (§10.4's citations are what
  #                  make this answerable at all)
  #
  #                  Citations are the model's self-report and can be wrong, so
  #                  this evidence is deliberately weak and deliberately one-way:
  #                  a *false* citation only suppresses a proposal, and a missed
  #                  one only produces a proposal a human then rejects. Nothing
  #                  here treats a citation as proof the rule was obeyed.
  #   duplicate      two active rules in the same bucket say the same thing
  #   superseded     the rule points at its replacement but is still in force
  #
  # It is idempotent: a second run proposes nothing new, so a weekly schedule does
  # not bury the operator in copies of last week's card.
  class RuleDreamingJob < ApplicationJob
    queue_as :default

    # A rule needs to have been in front of the agent this many times before
    # "never cited" means anything. Below it, silence is just a small sample.
    MIN_RUNS_BEFORE_STALE = 5

    # ...and to have been active at least this long, so a rule approved yesterday
    # is never up for retirement today.
    MIN_AGE_BEFORE_STALE = 14.days

    def perform(now: Time.current)
      Concierge::AgentRule.active.distinct.pluck(:agent_slug).each do |agent_slug|
        rules = Concierge::AgentRule.active.where(agent_slug: agent_slug).order(:id).to_a

        propose_retirements(rules, now)
        propose_merges(rules)
      end
    end

    private

    def propose_retirements(rules, now)
      rules.reject(&:retirement_proposed?).each do |rule|
        evidence = staleness_evidence(rule, now) || supersession_evidence(rule)
        next unless evidence

        Concierge::Rules.propose_retirement!(rule, evidence: evidence, by: dreamer)
      end
    end

    # Two active rules that say the same thing become one proposal that would
    # replace both. Activating it deprecates them with superseded_by pointing here
    # — the consolidation trail §10.2 asks for.
    def propose_merges(rules)
      seen = []

      rules.each do |rule|
        duplicates = Concierge::Rules::ConflictCheck.new(rule).conflicts
                       .select { |conflict| conflict["kind"] == "duplicate" }
                       .map { |conflict| conflict["rule_id"].to_i }
                       .select { |id| id > rule.id }
        next if duplicates.empty?

        group = ([ rule.id ] + duplicates).sort
        next if seen.any? { |previous| previous.intersect?(group) }
        next if already_proposed?(group)

        seen << group
        propose_merge(group)
      end
    end

    def propose_merge(ids)
      members = Concierge::AgentRule.where(id: ids).order(:id).to_a
      drafted  = Concierge::Rules::Generalizer.merge(members.map(&:body))
      return if drafted["body"].to_s.strip.empty?

      # The merged rule sits in the broadest bucket of the set: consolidating a
      # blanket rule with an account-specific copy of it should leave the blanket.
      Concierge::Rules.propose_like(
        broadest(members),
        body:       drafted["body"],
        author:     dreamer,
        provenance: {
          "source"   => "dreaming",
          "reason"   => "duplicate",
          "merges"   => ids,
          "evidence" => members.map { |rule| { "id" => rule.id, "body" => rule.body } }
        }
      )
    end

    def broadest(members)
      members.min_by { |rule| [ rule.subject_id ? 1 : 0, rule.segment ? 1 : 0, rule.id ] }
    end

    def staleness_evidence(rule, now)
      return if rule.activated_at.blank? || rule.activated_at > now - MIN_AGE_BEFORE_STALE

      injected = runs_injecting(rule)
      return if injected.size < MIN_RUNS_BEFORE_STALE
      return if injected.any? { |run| run.rule_ids_applied.map(&:to_i).include?(rule.id) }

      { "reason" => "never cited", "runs_injected" => injected.size,
        "active_since" => rule.activated_at.iso8601 }
    end

    def supersession_evidence(rule)
      return if rule.superseded_by_id.blank?

      { "reason" => "superseded", "superseded_by" => rule.superseded_by_id }
    end

    # Runs that had this rule in their prompt. The pins are serialized JSON, so
    # this filters in Ruby rather than pretending every adapter can index into it.
    def runs_injecting(rule)
      Concierge::AgentRun.where(agent_slug: rule.agent_slug).recent.limit(200).select do |run|
        run.injected_rule_ids.include?(rule.id)
      end
    end

    def already_proposed?(ids)
      Concierge::AgentRule.proposed.any? { |rule| rule.merges.sort == ids }
    end

    def dreamer
      Concierge::Rules.agent_actor("dreaming")
    end
  end
end
