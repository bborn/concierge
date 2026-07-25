module Concierge
  module Spike
    # SPIKE (phase-10 step 0, §10.1/§10.4). Throwaway — see lib/concierge/spike.rb.
    #
    # Concierge::Run, keyed by a Scope instead of a Subject. Kept as a separate
    # class rather than a branch inside Run so the spike stays deletable and so
    # the diff against Run *is* the report on how invasive step 1 will be. That
    # diff is small and mechanical:
    #
    #   @subject               -> @scope (and @scope.subject where a host record
    #                             is genuinely wanted, e.g. the Snapshot)
    #   @config.playbook       -> agent.playbook
    #   @config.capabilities   -> agent.capabilities
    #   @config.default_model  -> agent.model || @config.default_model
    #   ContextStore           -> Spike::MemoryStore
    #   (new) the kill switch and the provenance write
    class Run
      def self.reactive(scope, message)
        new(scope, trigger: { type: :reactive, message: message }).call
      end

      def self.proactive(scope, instruction:)
        new(scope, trigger: { type: :proactive, instruction: instruction,
                              message: instruction }).call
      end

      def initialize(scope, trigger:)
        @scope   = scope
        @trigger = trigger
        @config  = Concierge.config
      end

      def call
        # Slot 6: the kill switch. Ops can halt one business function without
        # touching the others, and without a deploy.
        return Result.suppressed(reason: "agent #{agent.slug.inspect} is disabled") unless agent.enabled?

        # Control is takeover, not gating (design §0.8) — unchanged, but now the
        # takeover is per (agent, subject): a human holding the billing thread
        # does not silence the CSM.
        if @trigger[:type] == :proactive && Handoff.active.for_scope(@scope).first
          return Result.suppressed(reason: "human has taken over this thread")
        end

        chat = build_chat(chat_record)
        chat.with_instructions(system_prompt)
        attach_tools(chat)

        reply = chat.ask(@trigger[:message])
        record_provenance(reply)
        success(reply)
      rescue RubyLLM::Error => e
        Result.failure(e, model: model)
      end

      def agent
        @scope.agent
      end

      private

      def subject
        @scope.subject
      end

      def model
        @model ||= agent.model || @config.default_model
      end

      def build_chat(record)
        @config.chat_factory.call(model: model, chat_record: record)
      end

      # One persistent conversation per (agent, subject). Under the spike's fake
      # this already works on the real table: Conversation's uniqueness validation
      # is scoped to subject_type, and the namespace lives there.
      def chat_record
        conversation = Conversation.find_by_scope(@scope) || create_conversation
        conversation.chat_record
      end

      def create_conversation
        chat = Concierge.chat_model.new
        chat.model = model if model
        if (provider = @config.default_provider)
          chat.provider = provider.to_s
          chat.assume_model_exists = true
        end
        chat.save!
        Conversation.create!(**@scope.key, grain: subject.grain.to_s, chat_id: chat.id)
      end

      # Slot 3 — this agent's tools, and only this agent's, each bound to the
      # scope and the namespaced store so a tool call cannot write outside it.
      def attach_tools(chat)
        tools = agent.capabilities.tools_for(subject, self, scope: @scope, store: memory_store)
        chat.with_tools(*tools) if tools.any?
      end

      def system_prompt
        [ role_line, product_brief, snapshot.to_prompt, memory_block, trigger_note ]
          .compact
          .join("\n\n")
      end

      def role_line
        persona = agent.playbook.persona
        line = "You are #{persona.name || 'the customer success manager'}, " \
               "the #{agent.slug} agent for this account."
        line += " Your voice is #{persona.voice}." if persona.voice
        line
      end

      def product_brief
        brief = agent.playbook.product_brief
        "About the product:\n#{brief}" if brief
      end

      def snapshot
        @snapshot ||= Snapshot.for(subject, playbook: agent.playbook)
      end

      def memories
        @memories ||= memory_store.top_of_mind(@scope).to_a
      end

      def memory_block
        return if memories.empty?

        "What you already know about this account:\n" +
          memories.map { |m| "- #{m.body}" }.join("\n")
      end

      def trigger_note
        return unless @trigger[:type] == :proactive && @trigger[:instruction]

        "You are reaching out proactively. Reason for this outreach:\n#{@trigger[:instruction]}"
      end

      # §10.4 — what went into this prompt, recorded against the agent that ran.
      def record_provenance(reply)
        Provenance.record(
          scope:           @scope,
          memory_ids:      memories.map(&:id),
          snapshot_digest: snapshot.digest,
          model:           model,
          trigger:         @trigger[:type],
          input_tokens:    reply.respond_to?(:input_tokens) ? reply.input_tokens : nil,
          output_tokens:   reply.respond_to?(:output_tokens) ? reply.output_tokens : nil
        )
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

      def memory_store
        @memory_store ||= MemoryStore.new
      end
    end
  end
end
