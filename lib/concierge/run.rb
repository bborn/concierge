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

      @chat_record = ChatResolver.call(@scope, model: model)
      @chat_id     = @chat_record&.id
      @message_watermark = last_host_message_id
      chat = build_chat(@chat_record)
      chat.with_instructions(system_prompt)
      attach_tools(chat)

      reply = chat.ask(@trigger[:message])
      success(reply)
    rescue RubyLLM::Error, RubyLLM::ConfigurationError, RubyLLM::ModelNotFoundError => e
      # Streaming may deliver partial tool-call args and errors mid-stream; the
      # harness absorbs both so a bad turn never crashes the host (design §6).
      #
      # ConfigurationError and ModelNotFoundError are listed separately because
      # RubyLLM derives them from StandardError, not from RubyLLM::Error — so a
      # host with no API key, or one asking for a model no registry it can reach
      # has heard of, was blowing straight through this rescue and out to the
      # caller, breaking the one promise this class makes. ChatResolver raises the
      # latter deliberately, on line 45 above, for a model that is genuinely
      # unknown; "genuinely unknown" is a failed Result like any other, not an
      # exception the host has to have thought about (task 5018).
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
      [ role_line, product_brief, snapshot_block, memory_block, rules_block,
        actions_block, trigger_note ]
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

    # What the host's product can do about whatever this turn writes
    # (docs/design/message-actions.md). The agent is told the vocabulary rather
    # than left to know it, which is the whole point: it picks, it never invents.
    def actions_block
      actions.to_prompt
    end

    def actions
      @actions ||= agent.actions || Actions.new
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

      # ...and the same for the actions line. Stripped whether or not this agent
      # declared a vocabulary, so a model that emits one unprompted cannot leak
      # a machine-readable trailer into a customer's inbox.
      selected      = Actions.extract(cited.text)
      offered       = actions.resolve(selected.keys)
      unknown_keys  = actions.unknown(selected.keys)
      log_unknown_actions(unknown_keys)

      record = record_provenance(
        status:           "ok",
        input_tokens:     token(reply, :input_tokens),
        output_tokens:    token(reply, :output_tokens),
        rule_ids_applied: cited.rule_ids,
        unknown_rule_ids: unknown,
        message_id:       persisted_reply_id,
        prompt_message_id: persisted_prompt_id
      )

      Result.new(
        reply_text:       selected.text,
        tool_calls:       reply.respond_to?(:tool_calls) ? reply.tool_calls : [],
        input_tokens:     token(reply, :input_tokens),
        output_tokens:    token(reply, :output_tokens),
        model:            model,
        rule_ids_applied: cited.rule_ids,
        unknown_rule_ids: unknown,
        run_record:       record,
        actions_offered:  offered,
        unknown_action_keys: unknown_keys
      )
    end

    # An offer key nobody declared shows nothing, but an operator should be able
    # to find out that the agent asked for it — a vocabulary the model keeps
    # reaching past is a vocabulary that is missing something.
    def log_unknown_actions(keys)
      return if keys.empty?

      Concierge.logger&.info(
        "[concierge] #{@scope.agent_slug} offered undeclared action(s) " \
        "#{keys.join(', ')} for #{subject.grain}##{subject.id}"
      )
    end

    def token(reply, name)
      reply.respond_to?(name) ? reply.public_send(name) : nil
    end

    # The host's own record of what the agent actually said on this turn — the
    # one thing the run row never held, and the only way a human can tell a turn
    # that followed a rule from one that contradicted it while citing it
    # (design §10.4). A pointer, not a copy: the words stay in the host's tables,
    # under the host's retention policy (§10.12).
    #
    # Only a message *this* turn created counts, which is what the watermark is
    # for. A host whose chat_factory does not persist — the documented offline
    # path, or any scripted double — leaves the chat untouched, and pointing an
    # operator at the previous turn's reply would be worse than pointing them at
    # nothing: they would spot-check the wrong words believing they were these.
    def persisted_reply_id
      newest_message_this_turn(role: "assistant")
    end

    # ...and the turn it answered. A reply read alone is thin evidence: the same
    # sentence is compliant or catastrophic depending on what was asked, so an
    # operator spot-checking a cited rule needs both halves. Watermarked exactly
    # like the reply, so a host whose factory persists nothing links to nothing
    # rather than to the previous turn's question.
    def persisted_prompt_id
      newest_message_this_turn(role: "user")
    end

    def newest_message_this_turn(role:)
      latest = host_messages&.where(role: role)&.maximum(:id)
      return unless latest
      return if @message_watermark && latest <= @message_watermark

      latest
    end

    def last_host_message_id
      host_messages&.maximum(:id)
    end

    # The host's messages for this run's chat, whatever it named the association.
    # A host chat model that keeps none is answered with nil rather than an
    # error — the reply link is an audit convenience, never a reason to fail a
    # turn.
    def host_messages
      return unless @chat_record
      return @chat_record.messages_association if @chat_record.respond_to?(:messages_association)

      @chat_record.messages if @chat_record.respond_to?(:messages)
    rescue StandardError => e
      Concierge.logger&.warn("[concierge] could not read host messages: #{e.class}: #{e.message}")
      nil
    end

    # Per-run provenance (§10.4): what this run was told, pinned. Written for runs
    # that reached the model — a suppressed run assembled no prompt, so there is
    # nothing to snapshot and a row would only add noise to the audit trail.
    #
    # Never lets an audit write fail the turn: the run happened whether or not we
    # managed to record it, and swallowing the reply would be the worse outcome.
    def record_provenance(status:, input_tokens: nil, output_tokens: nil,
                          rule_ids_applied: [], unknown_rule_ids: [], error_class: nil,
                          message_id: nil, prompt_message_id: nil)
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
        chat_id:          @chat_id,
        message_id:       message_id,
        prompt_message_id: prompt_message_id
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
