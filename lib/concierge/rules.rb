module Concierge
  # The rule lifecycle (design §10.2). Rules are the generalized, versioned half
  # of what Memory used to do, and unlike memory they have a gate: **no rule goes
  # active without a human tap, ever.** An agent may propose; only a person may
  # promote.
  #
  # The write path:
  #
  #   human correction  ->  stored verbatim as memory (Learning)
  #                     ->  out-of-band generalizer job drafts a rule
  #                     ->  conflict-checked, left `proposed` — a proposal card
  #                     ->  a human taps Approve  ->  `active`
  #
  # The read path:
  #
  #   Rules.active_for(scope)      the rules in force, broad -> specific
  #   Rules.playbook_section(...)  how they render into the prompt
  #   Rules.pins(...)              what the run snapshots: (id, version) pairs
  #
  # Everything that can refuse, refuses loudly and says what to do about it: the
  # active-rule cap raises a consolidation demand rather than silently truncating
  # the rule set (§10.12), and an unresolved conflict blocks activation rather
  # than letting two contradictory instructions coexist in one prompt.
  class Rules
    # How many active rules may be in force for one scope at once. The cap is the
    # forcing function that keeps rules generalized instead of accreting: hitting
    # it blocks, and the operator has to merge or retire something.
    DEFAULT_ACTIVE_CAP = 12

    # Actors the engine itself writes as. The prefix is reserved: an actor using
    # it can propose but can never approve, which is how "never agent
    # self-rewrite" is enforced structurally rather than by good intentions.
    AGENT_ACTOR_PREFIX = "agent:".freeze

    # The machine-readable line the agent ends its reply with, naming the rules it
    # applied. Stripped from the reply before anything reaches a customer.
    CITATION_PREFIX = "Rules-Applied:".freeze

    # A rule cannot go active without a human, and not without a *different*
    # human than the one (or agent) that drafted it.
    class GateError < Concierge::Error; end

    # The active-rule cap for this scope is full. Carries the rules to consolidate
    # so the message is actionable instead of just "no".
    class CapReached < Concierge::Error
      attr_reader :rule, :cap, :candidates

      def initialize(rule, cap, candidates)
        @rule       = rule
        @cap        = cap
        @candidates = candidates
        super(<<~MESSAGE.strip)
          #{rule.agent_slug} is already at its cap of #{cap} active rules for this scope, so rule #{rule.id} cannot go active.
          Consolidate or retire one of these first: #{candidates.map { |c| "##{c.id} #{c.body.to_s.truncate(60)}" }.join(' | ')}
        MESSAGE
      end
    end

    # An active rule in the same scope contradicts (or duplicates) this one. A
    # human resolves it — by superseding the old rule, editing one of them, or
    # explicitly acknowledging that both belong.
    class ConflictError < Concierge::Error
      attr_reader :rule, :conflicts

      def initialize(rule, conflicts)
        @rule      = rule
        @conflicts = conflicts
        super(<<~MESSAGE.strip)
          rule #{rule.id} conflicts with #{conflicts.size} active rule(s) in the same scope: #{conflicts.map { |c| "##{c['rule_id']} (#{c['kind']})" }.join(', ')}.
          Supersede one, edit them apart, or activate with acknowledge_conflicts: true.
        MESSAGE
      end
    end

    class << self
      # Draft a rule. Always lands in +proposed+ — this method has no path to
      # +active+, deliberately.
      #
      #   Rules.propose(scope, body: "Never quote a delivery date without checking the API.",
      #                 author: "dana@acme.test")
      #   Rules.propose(scope, body: "For EU accounts, cite the DPA.",
      #                 applies_to: :segment, segment: "eu", author: "...")
      #
      # +applies_to+ says how wide the rule reaches: +:subject+ (this account
      # only, the default), +:segment+, or +:agent+ (every account this business
      # function serves).
      def propose(target, body:, author: nil, applies_to: :subject, segment: nil,
                  predicate: nil, enforcement: :advisory, provenance: {})
        scope = Scope.coerce(target)
        create_proposal(
          keys_for(scope, applies_to, segment),
          body: body, author: author, predicate: predicate,
          enforcement: enforcement, provenance: provenance
        )
      end

      # Draft a rule keyed exactly like an existing one. The consolidation path
      # needs this: a merge proposal has to sit in the same bucket as the rules it
      # would replace, and an agent-wide rule has no Subject to build a Scope from.
      def propose_like(rule, body:, **options)
        create_proposal(
          { agent_slug: rule.agent_slug, subject_type: rule.subject_type,
            subject_id: rule.subject_id, segment: rule.segment },
          body: body, **options
        )
      end

      # The human tap. Requires an approver who is neither an agent nor the rule's
      # own author, refuses while a conflict is unresolved, and refuses at the cap.
      def activate!(rule, by:, supersede: nil, acknowledge_conflicts: false, note: nil)
        assert_human_gate!(rule, by)
        unless rule.proposed?
          raise GateError, "rule #{rule.id} is #{rule.state}, so there is nothing to approve"
        end

        # A one-for-one replacement has to free its slot before the cap is
        # counted, or consolidation would be impossible exactly when it is needed.
        supersede_with!(rule, supersede, by: by) if supersede
        assert_conflicts_resolved!(rule.reload, acknowledge_conflicts)
        assert_under_cap!(rule)

        rule.revision_context(actor: by, note: note || "activated")
        rule.update!(state: "active", approver: by, activated_at: Time.current)
        rule
      end

      # A proposal a human declined. Not +deprecated+: it never was in force, and
      # saying otherwise would misread the audit trail.
      def reject!(rule, by:, reason: nil)
        raise GateError, "rejecting a rule needs an actor" if by.to_s.strip.empty?

        rule.revision_context(actor: by, note: reason || "rejected")
        rule.update!(state: "rejected", approver: by,
                     provenance: rule.provenance.merge("rejected_reason" => reason).compact)
        rule
      end

      # Retire an active rule, optionally naming the rule that replaced it.
      def deprecate!(rule, by:, superseded_by: nil, reason: nil)
        raise GateError, "retiring a rule needs an actor" if by.to_s.strip.empty?

        rule.revision_context(actor: by, note: reason || "deprecated")
        rule.update!(
          state:            "deprecated",
          approver:         by,
          deprecated_at:    Time.current,
          superseded_by_id: superseded_by&.id,
          provenance:       rule.provenance.merge("deprecated_reason" => reason).compact
        )
        rule
      end

      # Edit the instruction. Version bumping is the model's job; this exists so
      # the trail records who changed it and why.
      def edit!(rule, by:, note: nil, **attributes)
        rule.revision_context(actor: by, note: note || "edited")
        rule.update!(**attributes)
        rule
      end

      # The weekly "dreaming" job's only power over an existing rule: ask, with
      # evidence, that a human retire it. It never retires anything itself.
      def propose_retirement!(rule, evidence:, by: nil)
        rule.update!(
          deprecation_proposed_at: Time.current,
          deprecation_evidence:    evidence.transform_keys(&:to_s).merge("proposed_by" => by).compact
        )
        notify_proposal(rule)
        rule
      end

      # The read path: every active rule in force for this (agent, account),
      # broad -> specific.
      def active_for(target)
        scope = Scope.coerce(target)
        AgentRule.active.applicable_to(scope, segments: segments_for(scope.subject))
      end

      # How the rules render into the run's prompt. Returns nil when there are
      # none, so the prompt simply has no Playbook section rather than an empty
      # heading.
      def playbook_section(rules)
        rules = rules.to_a
        return if rules.empty?

        [
          "Playbook — the rules in force here. A human approved each one; they " \
          "override your own judgement and the conventions you'd otherwise assume.",
          rules.map { |rule| "- #{rule.to_prompt}" }.join("\n"),
          "End your reply with a final line `#{CITATION_PREFIX} <ids>` naming the " \
          "rule ids you actually applied (or `#{CITATION_PREFIX} none`). That line " \
          "is stripped before the customer sees your reply."
        ].join("\n\n")
      end

      # What a run snapshots (§10.4): the exact (id, version) pairs it was given.
      # The version is the point — the text at that version stays recoverable from
      # the revision trail even after the rule is edited.
      def pins(rules)
        rules.map(&:pin)
      end

      # Guard rules (+enforcement: :guard+) carry a predicate the engine checks
      # itself, so a policy can graduate from "instruction the model should
      # follow" to "invariant that short-circuits the model" (§10.2). Returns the
      # rules an action would violate — empty means clear.
      #
      # §10.6's Proposal::Execute is the other caller-to-be; today the engine's
      # one dispatchable action class is the outbound message.
      def guard_violations(target, action_class:, payload: {})
        active_for(target).select(&:guard?).select do |rule|
          Guard.violates?(rule, action_class: action_class, payload: payload)
        end
      end

      # The named segments this subject belongs to, from the host's optional
      # +config.segments_for+ callable. Without one there are no segments, so
      # segment-scoped rules simply never apply — a host opts in.
      def segments_for(subject)
        hook = Concierge.config.segments_for
        return [] unless hook

        Array(hook.call(subject)).map(&:to_s)
      rescue StandardError => e
        Concierge.logger&.warn("[concierge] segments_for raised #{e.class}: #{e.message}")
        []
      end

      def cap
        Concierge.config.active_rule_cap || DEFAULT_ACTIVE_CAP
      end

      # The active rules competing for this rule's slot — what an operator has to
      # merge or retire when the cap blocks.
      #
      # The cap protects *one prompt*, so this is the set that would share the
      # fullest prompt this rule reaches. For an account-specific rule that is the
      # agent's blanket rules plus that account's own. For a blanket rule it is
      # the agent's blanket rules plus the **worst-affected** account's — because
      # a blanket rule lands in every account's prompt, and the cap has to hold in
      # the one that is already fullest.
      def consolidation_candidates(rule)
        others = AgentRule.active.where(agent_slug: rule.agent_slug).where.not(id: rule.id)
        (wide_rules(others).to_a + narrow_rules(others, rule).to_a).uniq.sort_by(&:id)
      end

      def at_cap?(rule)
        consolidation_candidates(rule).size >= cap
      end

      # The actor string the engine writes as. Reserved prefix: it can propose,
      # never approve.
      def agent_actor(agent_slug)
        "#{AGENT_ACTOR_PREFIX}#{agent_slug}"
      end

      def agent_actor?(actor)
        actor.to_s.start_with?(AGENT_ACTOR_PREFIX)
      end

      private

      # Blanket + segment rules: in force for every account (a segment rule only
      # for some, but the cap counts conservatively — over-counting costs an
      # operator a consolidation, under-counting costs an over-stuffed prompt).
      def wide_rules(others)
        others.where(subject_id: nil)
      end

      def narrow_rules(others, rule)
        return others.where(subject_type: rule.subject_type, subject_id: rule.subject_id) if rule.subject_id

        fullest = others.where.not(subject_id: nil)
                        .group(:subject_type, :subject_id).count
                        .max_by { |_keys, count| count }&.first
        return AgentRule.none unless fullest

        others.where(subject_type: fullest.first, subject_id: fullest.last)
      end

      # "Posts a proposal card." The engine's job is to make the card exist and
      # be addressable; *where* it is posted is the host's — Slack Block Kit, an
      # Avo screen, email. Without a notifier the card is still on
      # /concierge/admin/rules, which is why this is optional rather than a
      # required dependency on a chat transport.
      def create_proposal(keys, body:, author: nil, predicate: nil,
                          enforcement: :advisory, provenance: {})
        rule = AgentRule.new(
          **keys,
          body:        body.to_s.strip,
          state:       "proposed",
          author:      author,
          predicate:   predicate,
          enforcement: enforcement.to_s,
          provenance:  provenance.transform_keys(&:to_s)
        )
        rule.revision_context(actor: author, note: "proposed")
        rule.save!

        # Conflict-check at write time (§10.2): a contradiction surfaces on the
        # card for a human rather than silently coexisting in the next prompt.
        conflicts = ConflictCheck.new(rule).conflicts
        rule.update!(provenance: rule.provenance.merge("conflicts" => conflicts)) if conflicts.any?

        notify_proposal(rule)
        rule
      end

      def notify_proposal(rule)
        hook = Concierge.config.rule_proposal_notifier
        hook&.call(rule)
      rescue StandardError => e
        # A notifier is a side channel; a broken one must never lose the rule.
        Concierge.logger&.warn("[concierge] rule_proposal_notifier raised #{e.class}: #{e.message}")
      end

      def keys_for(scope, applies_to, segment)
        case applies_to.to_sym
        when :subject
          scope.key.merge(segment: segment&.to_s)
        when :agent
          { agent_slug: scope.agent_slug, segment: nil }
        when :segment
          raise Concierge::Error, "a segment-scoped rule needs a segment" if segment.to_s.strip.empty?

          { agent_slug: scope.agent_slug, segment: segment.to_s }
        else
          raise Concierge::Error,
                "unknown applies_to #{applies_to.inspect} (expected :subject, :segment or :agent)"
        end
      end

      def assert_human_gate!(rule, by)
        actor = by.to_s.strip
        raise GateError, "a rule cannot go active without a human approver" if actor.empty?

        if agent_actor?(actor)
          raise GateError,
                "#{actor} is an agent: an agent may propose a rule but never activate one"
        end

        return unless actor == rule.author.to_s

        raise GateError,
              "#{actor} drafted rule #{rule.id} and cannot also approve it (maker-checker)"
      end

      def assert_conflicts_resolved!(rule, acknowledged)
        return if acknowledged

        # A conflict against a rule that has since been retired is resolved.
        live = rule.conflicts.select do |conflict|
          AgentRule.active.exists?(id: conflict["rule_id"])
        end
        return if live.empty?

        raise ConflictError.new(rule, live)
      end

      def assert_under_cap!(rule)
        return unless at_cap?(rule)

        raise CapReached.new(rule, cap, consolidation_candidates(rule).to_a)
      end

      def supersede_with!(rule, superseded, by:)
        deprecate!(superseded, by: by, superseded_by: rule,
                   reason: "superseded by rule #{rule.id}")
        acknowledge_conflict(rule, superseded)
      end

      def acknowledge_conflict(rule, superseded)
        remaining = rule.conflicts.reject { |c| c["rule_id"].to_i == superseded.id }
        rule.update!(provenance: rule.provenance.merge("conflicts" => remaining,
                                                       "supersedes" => superseded.id))
      end
    end
  end
end
