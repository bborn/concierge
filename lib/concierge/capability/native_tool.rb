module Concierge
  module Capability
    # Base class for account-scoped native RubyLLM tools. Every built-in tool
    # subclasses this. A tool is constructed per run, bound to the current
    # Subject, and MUST reach data only through +scoped+ — the subject's
    # association scope — so a tool can never touch another account's rows
    # (design §6, the highest-severity risk).
    class NativeTool < RubyLLM::Tool
      attr_reader :subject, :run

      # +scope+ and +store+ are the (Agent × Subject) seam (design §10.1): when a
      # multi-agent runtime binds a Scope and its namespaced store, the tool keys
      # its rows by the pair; when nobody does, it keys by the Subject alone,
      # exactly as before. One tool class, both runtimes.
      def initialize(subject:, run: nil, scope: nil, store: nil)
        @subject = subject
        @run     = run
        @scope   = scope
        @store   = store
        super()
      end

      # What this tool's rows are keyed by. Both a Scope and a Subject answer
      # +#key+, so +Model.for_scope(scope)+ reads the same either way.
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

      # The memory store to write through: the namespaced one when a multi-agent
      # runtime injected it, the per-subject default otherwise.
      def context_store
        @context_store ||= @store || Concierge::ContextStore.new
      end
    end
  end
end
