module Concierge
  module Capability
    # The account-scoped tool registry. Native RubyLLM tools and (later) MCP tools
    # register here with a least-privilege grant. Tools are built per run, bound
    # to the current Subject, and handed to +chat.with_tools+.
    #
    #   config.capabilities do
    #     register Concierge::Tools::RecallTool,   access: :read
    #     register Concierge::Tools::RememberTool, access: :write
    #   end
    #
    # Write tools are only included when writes are granted for the run (default
    # on — the agent is autonomous within caps — but a caller can pass
    # include_writes: false to drop them).
    #
    # Registration is **declarative**: a tool is registered once no matter how
    # many times the host declares it. That is not a nicety. A host's
    # +Concierge.configure+ lives in +to_prepare+, which re-runs on every Rails
    # code reload, while the Configuration itself survives the reload (the gem is
    # not reloadable) — so an appending registry grows one full copy of the tool
    # list per reload in development, and hands +chat.with_tools+ the same tool
    # five times.
    class Registry
      Entry = Struct.new(:tool_class, :access)

      def initialize
        @entries = []
      end

      # Declare a tool. Re-declaring one replaces it in place — same position,
      # new access grant, new class object — rather than appending a duplicate.
      def register(tool_class, access: :read)
        entry = Entry.new(tool_class, access.to_sym)
        found = @entries.index { |e| identity(e.tool_class) == identity(tool_class) }

        found ? @entries[found] = entry : @entries << entry
        self
      end

      def clear
        @entries.clear
        self
      end

      def entries
        @entries.dup
      end

      # Per-run tool instances bound to +subject+ and, when the caller has one, to
      # the (Agent × Subject) +scope+ — so a tool call can never write outside the
      # agent's namespace (design §10.1). +scope+ defaults to nil, in which case
      # the tool keys its rows by the subject on the default agent.
      def tools_for(subject, run = nil, include_writes: true, scope: nil)
        @entries.filter_map do |entry|
          next if entry.access == :write && !include_writes

          entry.tool_class.new(subject: subject, run: run, scope: scope)
        end
      end

      private

      # A tool's identity is its *name*, not the Class object. A host tool that
      # lives in the host's +app/+ is a brand-new Class object after every code
      # reload, so keying on object identity would let host tools pile up exactly
      # the way gem tools used to — and would leave the registry pointing at the
      # stale, unloaded class. Anonymous classes (tests) have no name, so they
      # fall back to themselves.
      def identity(tool_class)
        tool_class.name || tool_class
      end
    end
  end
end
