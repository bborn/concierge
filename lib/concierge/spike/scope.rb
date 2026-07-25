module Concierge
  module Spike
    # SPIKE (phase-10 step 0, §10.1). Throwaway — see lib/concierge/spike.rb.
    #
    # The composite (Agent × Subject) identity that replaces the bare Subject as
    # the key of every Concierge table. Everywhere a run, tool, store, or job
    # takes a +subject+ today it takes a +scope+ instead.
    #
    #   scope = Concierge::Spike::Scope.new(agent, subject)
    #   Concierge::Memory.for_scope(scope)
    #
    # This is the load-bearing isolation invariant, now two-dimensional: no query
    # may cross an agent boundary *or* a subject boundary.
    class Scope
      # The reserved namespace for facts about the relationship that every agent
      # on a subject legitimately shares ("this account is in the EU"). Writes
      # default to the agent's own namespace; sharing is an explicit opt-in at
      # write time, and every agent reads its own namespace + this one (§10.3).
      SHARED = "_shared".freeze

      attr_reader :agent, :subject

      def initialize(agent, subject)
        @agent   = agent
        @subject = subject
      end

      def agent_slug
        agent.memory_namespace
      end

      # What step 1 will actually key rows by, once +agent_slug+ is a column on
      # the seven per-agent tables (§10.1/§10.9). Asserted in the spike's tests so
      # the shape we are committing to is written down in code, not just prose.
      def target_key
        { agent_slug: agent_slug }.merge(subject.key)
      end

      # --- The one spike fake -----------------------------------------------
      #
      # There is no +agent_slug+ column yet (this step migrates nothing), so the
      # spike folds the agent dimension into +subject_type+: "billing/account".
      # Every scoped query in the spike goes through this method, so step 1's
      # change is exactly `def key = target_key` plus the migration — and the
      # isolation tests written against #key keep meaning the same thing.
      def key
        { subject_type: "#{agent_slug}/#{subject.grain}", subject_id: subject.id.to_s }
      end

      # The same subject, in the shared namespace. Not an Agent — a namespace —
      # so it deliberately has no persona, tools, or authority to leak.
      def shared_key
        { subject_type: "#{SHARED}/#{subject.grain}", subject_id: subject.id.to_s }
      end

      def ==(other)
        other.is_a?(Scope) && other.agent_slug == agent_slug && other.subject == subject
      end
      alias eql? ==

      def hash
        [ agent_slug, subject.grain, subject.id ].hash
      end

      def to_s
        "#<Concierge::Spike::Scope #{agent_slug}:#{subject.grain}##{subject.id}>"
      end
    end
  end
end
