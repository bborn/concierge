module Concierge
  # The composite (Agent × Subject) identity that replaces the bare Subject as
  # the key of every per-agent Concierge table (design §10.1). Everywhere a run,
  # tool, store, or job took a +subject+ it now takes a +scope+.
  #
  #   scope = Concierge::Scope.new(agent, subject)
  #   Concierge::Memory.for_scope(scope)
  #
  # This is the load-bearing isolation invariant, now two-dimensional: no query
  # may cross an agent boundary *or* a subject boundary (§10.12).
  class Scope
    # The reserved namespace for facts about the relationship that every agent on
    # a subject legitimately shares ("this account is in the EU"). Writes default
    # to the agent's own namespace; sharing is an explicit opt-in at write time,
    # and every agent reads its own namespace + this one (§10.3).
    SHARED = "_shared".freeze

    attr_reader :agent, :subject

    def initialize(agent, subject)
      @agent   = agent
      @subject = subject
    end

    # Accepts a Scope or a bare Subject and always answers a Scope. A caller that
    # has no agent dimension yet (the whole single-agent surface, and every host
    # that never pluralized its config) lands on the default +:csm+ agent — which
    # is exactly the §10.9 back-compat rule, stated once.
    def self.coerce(target)
      return target if target.is_a?(Scope)

      new(Concierge.config.agent, target)
    end

    # Rebuild the Scope a persisted row was written under. A row travels as a
    # slug and an id because it has to outlive the process that wrote it, and
    # anything reading one back — a Slack card, a proposal, an inbound webhook —
    # needs the pair again before it may touch another table.
    #
    # Returns nil when either dimension no longer resolves: an agent removed from
    # the config, or a deleted account. That is inert data, not an error (step-0
    # spike §A1), and callers treat it as a refusal rather than crashing.
    def self.resolve(agent_slug:, subject_id:)
      agent = Concierge.config.agent(agent_slug)
      return unless agent

      subject = Concierge.config.account&.find_subject(subject_id)
      return unless subject

      new(agent, subject)
    rescue StandardError => e
      Concierge.logger&.warn("[concierge] could not resolve scope " \
                             "#{agent_slug}/#{subject_id}: #{e.class}: #{e.message}")
      nil
    end

    # The subject half of a key, from either a Scope or a bare Subject. Tables
    # that deliberately have no agent dimension — +concierge_outreach_preferences+
    # is the customer's preference about being contacted at all, not one agent's
    # private setting — narrow by this.
    def self.subject_key(target)
      target.is_a?(Scope) ? target.subject.key : target.key
    end

    def agent_slug
      agent.memory_namespace
    end

    # What every per-agent table keys a row by: the agent dimension merged onto
    # the subject pair the engine has always used.
    def key
      { agent_slug: agent_slug }.merge(subject.key)
    end

    # The same subject, in the shared namespace. Not an Agent — a namespace — so
    # it deliberately has no persona, tools, or authority to leak.
    def shared_key
      { agent_slug: SHARED }.merge(subject.key)
    end

    # Value semantics are load-bearing: the isolation grid keys cells by Scope,
    # and without these two it silently collapses.
    def ==(other)
      other.is_a?(Scope) && other.agent_slug == agent_slug && other.subject == subject
    end
    alias eql? ==

    def hash
      [ agent_slug, subject.grain, subject.id ].hash
    end

    def to_s
      "#<Concierge::Scope #{agent_slug}:#{subject.grain}##{subject.id}>"
    end
  end
end
