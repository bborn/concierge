module Concierge
  module Capability
    # Base class for account-scoped native RubyLLM tools. Every built-in tool
    # subclasses this. A tool is constructed per run, bound to the current
    # Subject, and MUST reach data only through +scoped+ — the subject's
    # association scope — so a tool can never touch another account's rows
    # (design §6, the highest-severity risk).
    class NativeTool < RubyLLM::Tool
      attr_reader :subject, :run

      def initialize(subject:, run: nil)
        @subject = subject
        @run     = run
        super()
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

      def context_store
        @context_store ||= Concierge::ContextStore.new
      end
    end
  end
end
