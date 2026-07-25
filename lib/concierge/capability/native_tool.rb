module Concierge
  module Capability
    # Base class for account-scoped native RubyLLM tools. Every built-in tool
    # subclasses this. A tool is constructed per run, bound to the current
    # Subject, and MUST reach data only through +scoped+ — the subject's
    # association scope — so a tool can never touch another account's rows
    # (design §6, the highest-severity risk).
    class NativeTool < RubyLLM::Tool
      attr_reader :subject, :run

      # +scope+ is the (Agent × Subject) seam (design §10.1): a run binds the Scope
      # it is executing under, and every row this tool writes is keyed by that
      # pair. Left nil, the tool keys by the subject on the default agent — which
      # is the same rule Scope.coerce states for queries, so one tool class works
      # whether or not the caller has an agent dimension.
      def initialize(subject:, run: nil, scope: nil)
        @subject = subject
        @run     = run
        @scope   = scope
        super()
      end

      # What this tool's rows are keyed by. Both a Scope and a Subject are
      # accepted everywhere downstream, so +Model.for_scope(scope)+ and
      # +context_store.remember(scope, …)+ read the same either way.
      def scope
        @scope || @subject
      end

      # What RubyLLM calls. Subclasses implement +perform+ instead, so no tool has
      # to repeat the rescue: a raising tool reports the error back into the tool
      # loop rather than crashing the run.
      def execute(**args)
        perform(**args)
      rescue => e
        { error: e.message }
      end

      protected

      # Subclasses implement the actual work here.
      def perform(**_args)
        raise NotImplementedError
      end

      # The only sanctioned data path for a tool: an account-scoped relation.
      def scoped(association)
        subject.scope_for(association)
      end

      # The memory store to write through. It is scope-keyed, so passing +scope+
      # is all a tool has to do to stay inside its agent's namespace.
      def context_store
        @context_store ||= Concierge::ContextStore.new
      end
    end
  end
end
