module Concierge
  # The load-bearing isolation invariant, now two-dimensional (design §10.1,
  # §10.12): every per-agent table is keyed by the (Agent × Subject) pair, and
  # **no query may cross an agent boundary or a subject boundary.**
  #
  #   Concierge::Memory.for_scope(scope)   # => this agent, this subject
  #
  # +for_scope+ takes a Scope or a bare Subject; a bare Subject is coerced onto
  # the default +:csm+ agent, so the single-agent surface — and every host that
  # never pluralized its config — keeps its exact behaviour (§10.9). That is also
  # why +for_subject+ is *not* left as a wide "all agents" query: silently
  # widening the oldest scope in the codebase is precisely the leak this concern
  # exists to prevent. It is deliberately NOT built on SubjectScoped: that concern
  # narrows by the subject alone, which on these tables would be that same leak.
  module AgentScoped
    extend ActiveSupport::Concern

    included do
      scope :for_subject, ->(subject) { where(Scope.coerce(subject).key) }
      scope :for_scope,   ->(scope) { where(Scope.coerce(scope).key) }

      # Every agent on a subject reads its own namespace plus the reserved shared
      # one (§10.3); writes land in the agent's own namespace unless a caller
      # explicitly opts into sharing. Reads must fold the shared namespace in or
      # it would be write-only, and therefore pointless.
      scope :for_scope_including_shared, ->(scope) {
        scope = Scope.coerce(scope)
        where(scope.subject.key).where(agent_slug: [ scope.agent_slug, Scope::SHARED ])
      }

      validates :agent_slug, presence: true

      # A row written without *any* namespace belongs to the default agent — the
      # row-level half of the same back-compat rule Scope.coerce states for
      # queries. A namespace that was set to blank on purpose is a bug, not a
      # back-compat case, so the validation above still has something to catch.
      before_validation :default_agent_slug
    end

    class_methods do
      def find_by_subject(subject)
        find_by(Scope.coerce(subject).key)
      end

      def find_by_scope(scope)
        find_by(Scope.coerce(scope).key)
      end
    end

    private

    def default_agent_slug
      self.agent_slug = Configuration::DEFAULT_AGENT_SLUG.to_s if agent_slug.nil?
    end
  end
end
