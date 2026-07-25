module Concierge
  # The out-of-band half of the rule write path (design §10.2): a human correction
  # was stored verbatim; this drafts a generalized rule from it, conflict-checks
  # it, and leaves it +proposed+ for a human.
  #
  # It cannot activate anything. It authors as +agent:<slug>+, and
  # Rules.activate! refuses that actor by construction — so "no rule active
  # without a human tap, never agent self-rewrite" is a property of the code
  # rather than a convention this job is trusted to honour.
  #
  # Takes a memory id rather than a Scope because job arguments have to serialize,
  # and the memory row already carries the (agent, subject) keys the correction
  # arrived under.
  class RuleGeneralizerJob < ApplicationJob
    queue_as :default

    def perform(memory_id, author: nil, provenance: {})
      memory = Concierge::Memory.find_by(id: memory_id)
      return unless memory

      scope = scope_for(memory)
      return unless scope

      # ActiveJob delivery is at-least-once, so a retry after the propose
      # succeeded would post a second identical card for one correction. One
      # correction, one proposal.
      return if already_drafted?(memory)

      drafted = Concierge::Rules::Generalizer.call(memory.body)
      return if drafted["body"].to_s.strip.empty?

      Concierge::Rules.propose(
        scope,
        body:        drafted["body"],
        predicate:   drafted["predicate"],
        enforcement: drafted["enforcement"] || "advisory",
        author:      Concierge::Rules.agent_actor(scope.agent_slug),
        provenance:  provenance.merge(
          "source"       => "human_correction",
          "memory_id"    => memory.id,
          "verbatim"     => memory.body,
          "corrected_by" => author
        ).compact
      )
    end

    private

    # The correction id is the idempotency key. Checked across every state: a
    # proposal a human already rejected must not come back on a retry either.
    def already_drafted?(memory)
      Concierge::AgentRule.where(agent_slug: memory.agent_slug).any? do |rule|
        rule.provenance["memory_id"] == memory.id
      end
    end

    # An agent that was removed from config, or an account that has since gone
    # away, makes the correction inert data rather than an error (the same rule
    # SweepJob follows for orphaned routines).
    def scope_for(memory)
      agent = Concierge.config.agent(memory.agent_slug)
      return unless agent

      subject = Concierge.config.account.find_subject(memory.subject_id)
      return unless subject

      Concierge::Scope.new(agent, subject)
    end
  end
end
