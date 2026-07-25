module Concierge
  # One turn of one agent for a single account: assembles the prompt (the agent's
  # role/persona + product brief + fresh Snapshot + top-of-mind memory), attaches
  # that agent's tools and only that agent's, drives one +chat.ask+ on the
  # (agent, subject) persistent Chat, and returns a structured Result. It never
  # raises out to the caller — a provider error mid-stream comes back as a failed
  # Result.
  #
  # Both entry points take a Scope or a bare Subject; a bare Subject is coerced
  # onto the default +:csm+ agent, so a single-agent host's call sites are
  # unchanged (design §10.9).
  class Run
    def self.reactive(scope, message)
      new(scope, trigger: { type: :reactive, message: message }).call
    end

    # Proactive turn framed by a trigger (a routine or lifecycle event). The
    # instruction shapes what the agent reaches out about; there is no inbound
    # customer message.
    def self.proactive(scope, instruction:)
      new(scope, trigger: { type: :proactive, instruction: instruction,
                            message: instruction }).call
    end

    def initialize(scope, trigger:)
      @scope   = Scope.coerce(scope)
      @trigger = trigger
      @config  = Concierge.config
    end

    attr_reader :scope

    def call
      # Slot 6: the kill switch. Ops can halt one business function without
      # touching the others, and without a deploy.
      return Result.suppressed(reason: "agent #{agent.slug.inspect} is disabled") unless agent.enabled?

      # Control is takeover, not gating: while a human holds *this agent's*
      # thread, suppress autonomous proactive sends (design §0.8). Reactive turns
      # still answer, and a takeover on one agent does not silence another.
      if @trigger[:type] == :proactive && Handoff.active_for(@scope)&.active?
        return Result.suppressed(reason: "human has taken over this thread")
      end

      chat_record = ChatResolver.call(@scope, model: model)
      chat = build_chat(chat_record)
      chat.with_instructions(system_prompt)
      attach_tools(chat)

      reply = chat.ask(@trigger[:message])
      success(reply)
    rescue RubyLLM::Error => e
      # Streaming may deliver partial tool-call args and errors mid-stream; the
      # harness absorbs both so a bad turn never crashes the host (design §6).
      Result.failure(e, model: model)
    end

    def agent
      @scope.agent
    end

    private

    def subject
      @scope.subject
    end

    # The agent's own model when it named one, else the house default.
    def model
      @model ||= agent.model || @config.default_model
    end

    def build_chat(chat_record)
      @config.chat_factory.call(model: model, chat_record: chat_record)
    end

    # Slot 3 — this agent's tools, and only this agent's, each bound to the scope
    # so a tool call mid-run cannot write outside the agent's namespace. A tool
    # that is off-scope for this agent was never registered, so it does not exist
    # in this loop rather than existing and erroring.
    def attach_tools(chat)
      registry = agent.capabilities
      return unless registry

      tools = registry.tools_for(subject, self, scope: @scope)
      chat.with_tools(*tools) if tools.any?
    end

    # System prompt = role/persona + product brief + fresh account snapshot +
    # top-of-mind memory. Assembled fresh every run so the agent always reasons
    # over current state.
    def system_prompt
      [ role_line, product_brief, snapshot_block, memory_block, trigger_note ]
        .compact
        .join("\n\n")
    end

    def role_line
      persona = playbook.persona
      line = "You are #{persona.name || 'the customer success manager'}, " \
             "the #{agent.slug} agent for this account."
      line += " Your voice is #{persona.voice}." if persona.voice
      line
    end

    def product_brief
      brief = playbook.product_brief
      "About the product:\n#{brief}" if brief
    end

    # An agent does not get a different *account*; it gets a different view of
    # one — its own engagement signals over the same subject. So the Snapshot
    # stays subject-keyed and takes this agent's playbook, and two agents over one
    # account legitimately produce two different digests.
    def snapshot_block
      return if playbook.engagement_signals.empty?

      Snapshot.for(subject, playbook: playbook).to_prompt
    end

    def memory_block
      memories = context_store.top_of_mind(@scope)
      return if memories.empty?

      "What you already know about this account:\n" +
        memories.map { |m| "- #{m.body}" }.join("\n")
    end

    def trigger_note
      return unless @trigger[:type] == :proactive && @trigger[:instruction]

      "You are reaching out proactively. Reason for this outreach:\n#{@trigger[:instruction]}"
    end

    def success(reply)
      Result.new(
        reply_text:    reply.content,
        tool_calls:    reply.respond_to?(:tool_calls) ? reply.tool_calls : [],
        input_tokens:  reply.respond_to?(:input_tokens) ? reply.input_tokens : nil,
        output_tokens: reply.respond_to?(:output_tokens) ? reply.output_tokens : nil,
        model:         model
      )
    end

    def playbook
      agent.playbook
    end

    def context_store
      @context_store ||= Concierge::ContextStore.new
    end
  end
end
