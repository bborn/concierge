module Concierge
  # One turn of the customer success agent for a single account: assembles the
  # prompt (CSM role + product brief + fresh Snapshot + top-of-mind memory),
  # attaches the account-scoped tools, drives one +chat.ask+ on the subject's
  # persistent Chat, and returns a structured Result. It never raises out to the
  # caller — a provider error mid-stream comes back as a failed Result.
  #
  # Reactive path (customer message → reply) ships here; the proactive path lands
  # in Phase 7.
  class Run
    def self.reactive(subject, message)
      new(subject, trigger: { type: :reactive, message: message }).call
    end

    # Proactive turn framed by a trigger (a routine or lifecycle event). The
    # instruction shapes what the agent reaches out about; there is no inbound
    # customer message.
    def self.proactive(subject, instruction:)
      new(subject, trigger: { type: :proactive, instruction: instruction,
                              message: instruction }).call
    end

    def initialize(subject, trigger:)
      @subject = subject
      @trigger = trigger
      @config  = Concierge.config
    end

    def call
      # Control is takeover, not gating: while a human holds the thread, suppress
      # autonomous proactive sends (design §0.8). Reactive turns still answer.
      if @trigger[:type] == :proactive && Handoff.active_for(@subject)&.active?
        return Result.suppressed(reason: "human has taken over this thread")
      end

      chat_record = ChatResolver.call(@subject, model: model)
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

    private

    def model
      @model ||= @config.default_model
    end

    def build_chat(chat_record)
      @config.chat_factory.call(model: model, chat_record: chat_record)
    end

    def attach_tools(chat)
      registry = @config.capabilities
      return unless registry

      tools = registry.tools_for(@subject, self)
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
      persona = playbook&.persona
      line = "You are #{persona&.name || 'the customer success manager'}, " \
             "an always-on customer success manager for this account."
      line += " Your voice is #{persona.voice}." if persona&.voice
      line
    end

    def product_brief
      brief = playbook&.product_brief
      "About the product:\n#{brief}" if brief
    end

    def snapshot_block
      return unless playbook

      Snapshot.for(@subject).to_prompt
    end

    def memory_block
      memories = context_store.top_of_mind(@subject)
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
      @config.playbook
    end

    def context_store
      @context_store ||= Concierge::ContextStore.new
    end
  end
end
