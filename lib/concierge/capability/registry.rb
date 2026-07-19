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
    class Registry
      Entry = Struct.new(:tool_class, :access)

      def initialize
        @entries = []
      end

      def register(tool_class, access: :read)
        @entries << Entry.new(tool_class, access.to_sym)
        self
      end

      def clear
        @entries.clear
        self
      end

      def entries
        @entries.dup
      end

      # Per-run tool instances bound to +subject+.
      def tools_for(subject, run = nil, include_writes: true)
        @entries.filter_map do |entry|
          next if entry.access == :write && !include_writes

          entry.tool_class.new(subject: subject, run: run)
        end
      end

      # The array to pass to +chat.with_tools(*...)+.
      alias for_llm tools_for
    end
  end
end
