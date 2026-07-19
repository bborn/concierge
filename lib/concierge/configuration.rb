module Concierge
  # The single configuration surface for the gem. A host sets this up once, in an
  # initializer, via +Concierge.configure+. Each boundary (account, playbook,
  # capabilities, channels, governance) hangs off this object; later phases fill
  # the currently-empty slots with their own small builder DSLs.
  class Configuration
    # The RubyLLM model id used when a run doesn't override it (e.g.
    # "claude-sonnet-4-5"). Hosts almost always set this.
    attr_accessor :default_model

    # The host's RubyLLM chat model class name. Concierge reuses the host-owned
    # +Chat+ table rather than owning conversations itself.
    attr_accessor :chat_model_name

    # When true, autonomous sends are diverted to an outbox for human review
    # instead of being delivered. Off by default — Concierge is autonomous within
    # its caps (see the ChannelBridge governance layer).
    attr_accessor :draft_and_review

    # A callable that returns the RubyLLM chat object a run should drive. The
    # default builds a fresh +RubyLLM.chat+; the test suite swaps in a scripted
    # double so no network call ever happens in CI. Signature:
    #
    #   ->(model:, chat_record:) { ... returns something that responds to #ask }
    attr_accessor :chat_factory

    # Boundaries filled in by later phases. Nil until the host configures them.
    attr_accessor :account       # AccountAdapter          (Phase 1)
    attr_accessor :playbook      # Playbook                (Phase 2)
    attr_accessor :capabilities  # Capability::Registry    (Phase 4)
    attr_accessor :channels      # Channel registry        (Phase 6)
    attr_accessor :governance    # Governance settings     (Phase 6)

    def initialize
      @chat_model_name  = "Chat"
      @draft_and_review = false
      @chat_factory     = DEFAULT_CHAT_FACTORY
    end

    # Default chat factory: prefer resuming the persisted conversation (RubyLLM's
    # +acts_as_chat+ gives records a +to_llm+), else a fresh in-memory chat.
    DEFAULT_CHAT_FACTORY = lambda do |model:, chat_record: nil|
      if chat_record.respond_to?(:to_llm)
        chat_record.to_llm
      else
        RubyLLM.chat(model: model)
      end
    end
  end
end
