module Concierge
  module Test
    # A scripted stand-in for a RubyLLM chat object so the suite never makes a
    # network/LLM call. It mirrors the fluent builder surface Concierge::Run
    # relies on (+with_instructions+, +with_tools+, ...), records what it was
    # given for assertions, and returns canned replies.
    #
    # A test scripts the next chat via the class-level helpers and points the
    # gem's +chat_factory+ at +FakeChat.current+ (done in test_helper):
    #
    #   Concierge::Test::FakeChat.script(reply: "Hello!")
    #   Concierge::Test::FakeChat.script(tool_calls: [{ name: "remember", arguments: { body: "x" } }])
    #   Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))
    class FakeChat
      Reply = Struct.new(:content, :tool_calls, :input_tokens, :output_tokens, keyword_init: true) do
        def initialize(content: "", tool_calls: [], input_tokens: 0, output_tokens: 0)
          super
        end
      end

      class << self
        # The chat the next run should receive. Reset in test setup.
        attr_accessor :current

        # Script one canned assistant turn and make it the current chat.
        def script(reply: "ok", tool_calls: [], input_tokens: 10, output_tokens: 5)
          self.current = new(replies: [
            Reply.new(content: reply, tool_calls: tool_calls,
                      input_tokens: input_tokens, output_tokens: output_tokens)
          ])
        end

        # Script a chat whose +ask+ raises, to exercise error handling.
        def raise_with(error)
          chat = new(replies: [])
          chat.error_to_raise = error
          self.current = chat
        end

        def reset!
          self.current = nil
        end
      end

      attr_reader :instructions, :prompts, :tools
      attr_accessor :error_to_raise

      def initialize(replies: [])
        @replies      = replies
        @instructions = []
        @prompts      = []
        @tools        = []
      end

      # --- Fluent builder surface (all chainable, most are recording no-ops) ---

      def with_instructions(text, replace: false)
        @instructions.clear if replace
        @instructions << text.to_s
        self
      end

      def with_temperature(_value) = self
      def with_context(_context)   = self
      def with_params(**)          = self

      def with_tools(*tools)
        @tools.concat(tools.flatten)
        self
      end

      # --- The run entry point ---

      # Pops the next scripted reply. Executes any scripted tool calls against the
      # registered tools first, so tool-loop side effects (e.g. a memory write)
      # actually happen — that's what run/tool tests assert on.
      def ask(prompt, &block)
        @prompts << prompt
        raise @error_to_raise if @error_to_raise

        reply = @replies.shift || Reply.new
        Array(reply.tool_calls).each { |call| invoke_tool(call) }
        yield reply if block
        reply
      end

      # All instructions concatenated — convenient for prompt-assembly assertions.
      def system_prompt
        @instructions.join("\n")
      end

      private

      def invoke_tool(call)
        name = (call[:name] || call["name"]).to_s
        args = (call[:arguments] || call["arguments"] || {}).transform_keys(&:to_sym)
        tool = @tools.find { |t| tool_name(t) == name }
        tool&.execute(**args)
      end

      def tool_name(tool)
        if tool.respond_to?(:name)
          tool.name.to_s
        else
          tool.class.name.to_s.split("::").last.gsub(/Tool$/, "").downcase
        end
      end
    end
  end
end
