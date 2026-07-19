module Concierge
  module Capability
    # Seam for connecting customer/host MCP servers as tools. RubyLLM tools and
    # MCP tools unify at +with_tools+, so an MCP-backed tool can register in the
    # same Registry as a native one.
    #
    # v1 ships the seam only — customer-connected MCP is deferred (design §7), so
    # the gem takes no hard dependency on ruby_llm-mcp. A host that wants it adds
    # the gem and wraps its clients here. Transports: :stdio, :sse, :streamable.
    class McpAdapter
      # Build tool objects from an MCP client config. Intentionally unimplemented
      # in v1 so wiring it up is an explicit, reviewed choice rather than a silent
      # capability.
      def self.for(_config)
        raise NotImplementedError,
              "customer MCP is deferred in v1 (design §7); add ruby_llm-mcp and " \
              "implement Concierge::Capability::McpAdapter.for to enable it"
      end
    end
  end
end
