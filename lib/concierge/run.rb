module Concierge
  # One turn of one agent for a single account: assembles the prompt (the agent's
  # role/persona + product brief + fresh Snapshot + top-of-mind memory + the rules
  # in force), attaches that agent's tools and only that agent's, drives one
  # +chat.ask+ on the (agent, subject) persistent Chat, records what went into the
  # prompt, and returns a structured Result. It never raises out to the caller — a
  # provider error mid-stream comes back as a failed Result.
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
      @chat_id    = chat_record&.id
      chat = build_chat(chat_record)
      chat.with_instructions(system_prompt)
      attach_tools(chat)

      reply = chat.ask(@trigger[:message])
      success(reply)
    rescue RubyLLM::Error => e
      # Streaming may deliver partial tool-call args and errors mid-stream; the
      # harness absorbs both so a bad turn never crashes the host (design §6).
      record_provenance(status: "failed", error_class: e.class.name)
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
    # top-of-mind memory + the Playbook rules in force. Assembled fresh every run
    # so the agent always reasons over current state and current policy.
    def system_prompt
      [ role_line, product_brief, snapshot_block, memory_block, rules_block, trigger_note ]
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

      snapshot.to_prompt
    end

    def snapshot
      @snapshot ||= Snapshot.for(subject, playbook: playbook)
    end

    def memory_block
      return if memories.empty?

      "What you already know about this account:\n" +
        memories.map { |m| "- #{m.body}" }.join("\n")
    end

    def memories
      @memories ||= context_store.top_of_mind(@scope).to_a
    end

    # The Playbook section (§10.2): the human-approved rules in force for this
    # (agent, account), rendered with their ids so the agent can cite what it
    # applied — and so an auditor can resolve the exact text it was given.
    def rules_block
      Rules.playbook_section(rules)
    end

    def rules
      @rules ||= Rules.active_for(@scope).to_a
    end

    def trigger_note
      return unless @trigger[:type] == :proactive && @trigger[:instruction]

      "You are reaching out proactively. Reason for this outreach:\n#{@trigger[:instruction]}"
    end

    def success(reply)
      # The citation line is audit metadata, not copy: pull the ids out and strip
      # the line so it can never reach a customer through Outreach.
      cited   = Rules::Citation.extract(reply.content)
      unknown = Rules::Citation.unknown(cited.rule_ids, rules.map(&:id))

      record = record_provenance(
        status:           "ok",
        input_tokens:     token(reply, :input_tokens),
        output_tokens:    token(reply, :output_tokens),
        rule_ids_applied: cited.rule_ids,
        unknown_rule_ids: unknown
      )

      Result.new(
        reply_text:       cited.text,
        tool_calls:       reply.respond_to?(:tool_calls) ? reply.tool_calls : [],
        input_tokens:     token(reply, :input_tokens),
        output_tokens:    token(reply, :output_tokens),
        model:            model,
        rule_ids_applied: cited.rule_ids,
        unknown_rule_ids: unknown,
        run_record:       record
      )
    end

    def token(reply, name)
      reply.respond_to?(name) ? reply.public_send(name) : nil
    end

    # Per-run provenance (§10.4): what this run was told, pinned. Written for runs
    # that reached the model — a suppressed run assembled no prompt, so there is
    # nothing to snapshot and a row would only add noise to the audit trail.
    #
    # Never lets an audit write fail the turn: the run happened whether or not we
    # managed to record it, and swallowing the reply would be the worse outcome.
    def record_provenance(status:, input_tokens: nil, output_tokens: nil,
                          rule_ids_applied: [], unknown_rule_ids: [], error_class: nil)
      AgentRun.create!(
        **@scope.key,
        trigger:          @trigger[:type].to_s,
        status:           status,
        model:            model,
        input_tokens:     input_tokens,
        output_tokens:    output_tokens,
        snapshot_digest:  snapshot.digest,
        memory_ids:       memories.map(&:id),
        rules:            Rules.pins(rules),
        rule_ids_applied: rule_ids_applied,
        unknown_rule_ids: unknown_rule_ids,
        error_class:      error_class,
        chat_id:          @chat_id
      )
    rescue StandardError => e
      Concierge.logger&.warn("[concierge] could not record run provenance: #{e.class}: #{e.message}")
      nil
    end

    def playbook
      agent.playbook
    end

    def context_store
      @context_store ||= Concierge::ContextStore.new
    end
  end
end
