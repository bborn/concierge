module Concierge
  # The single configuration surface for the gem. A host sets this up once, in an
  # initializer, via +Concierge.configure+. Each boundary (account, playbook,
  # capabilities, channels, governance) hangs off this object; later phases fill
  # the currently-empty slots with their own small builder DSLs.
  class Configuration
    # The RubyLLM model id used when a run doesn't override it (e.g.
    # "claude-sonnet-4-5"). Hosts almost always set this.
    attr_accessor :default_model

    # Optional provider for +default_model+ (e.g. :anthropic). When set, the
    # persistent Chat is created with the model assumed-to-exist, so record
    # creation never consults the model registry or resolves RubyLLM's *global*
    # default provider — which would otherwise demand credentials for a provider
    # Concierge doesn't use. Leave nil to let RubyLLM resolve the model normally.
    attr_accessor :default_provider

    # The host's RubyLLM chat model class name. Concierge reuses the host-owned
    # +Chat+ table rather than owning conversations itself.
    attr_accessor :chat_model_name

    # Optional logger override. Defaults to the Rails logger via Concierge.logger.
    attr_accessor :logger

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

    # --- ChannelBridge (Phase 6) ---

    # Ordered list of channel classes the router considers, most-preferred first.
    attr_accessor :channels

    # Callable(subject) -> email address, so the gem stays schema-agnostic.
    attr_accessor :email_address_for

    # Callable(subject, payload) that surfaces an in-app message (Turbo broadcast).
    attr_accessor :in_app_broadcaster

    # Host used to build absolute unsubscribe URLs in emails.
    attr_accessor :mailer_host

    # Optional overrides: frequency-cap windows and the usefulness bar.
    attr_accessor :frequency_windows
    attr_accessor :usefulness_check

    # --- Routines + proactive runtime (Phase 7) ---

    # Token budgets for proactive work: { per_tenant:, global: }. Nil = unlimited.
    attr_accessor :budget

    # Callable(subject) -> per-account token cap override (global rail still binds).
    attr_accessor :budget_override_for

    # Callable(subject) -> numeric priority score (higher spends budget first).
    attr_accessor :priority

    # The v1 built-in weekly review: whether it runs, and its framing instruction.
    attr_accessor :weekly_review_enabled
    attr_accessor :weekly_review_instruction

    # --- Admin surface (Phase 9) ---

    # Callable(controller) -> truthy to permit admin access. Nil = deny (the admin
    # fails closed rather than shipping an open dashboard).
    attr_accessor :authenticate_admin

    # --- Multi-agent spike (Phase 10, step 0 — throwaway; see Concierge::Spike) ---

    # Turns on the (Agent × Subject) prototype: the plural +agent+ DSL below still
    # parses without it, but nothing in the engine acts on it. Off by default.
    attr_accessor :multi_agent_spike

    def initialize
      @chat_model_name  = "Chat"
      @draft_and_review = false
      @multi_agent_spike = false
      @chat_factory     = DEFAULT_CHAT_FACTORY
      @agents           = {}
    end

    # Declare what an account is. With a block, builds and stores the adapter;
    # without one, returns the configured adapter (or nil).
    #
    #   config.account do
    #     subject_class Tenant
    #     attribute(:plan) { |t| t.plan }
    #   end
    def account(&block)
      if block
        @account = AccountAdapter.new
        @account.instance_eval(&block)
      end
      @account
    end

    # Declare what the app does and what "engaged" means. With a block, builds
    # and stores the Playbook; without one, returns it (or nil).
    def playbook(&block)
      if block
        @playbook = Playbook.new
        @playbook.instance_eval(&block)
      end
      @playbook
    end

    # Declare which tools the agent may use. The block runs against a fresh
    # Capability::Registry; without a block, returns the registry (built lazily
    # so hosts can register incrementally).
    def capabilities(&block)
      @capabilities ||= Capability::Registry.new
      @capabilities.instance_eval(&block) if block
      @capabilities
    end

    # The default agent an un-pluralized host implicitly is (design §10.9).
    DEFAULT_AGENT_SLUG = :csm

    # Declare a business function. Same setter/reader rule as every other block:
    # with a block it defines, bare it reads back the resolved agent.
    #
    #   c.agent :csm do
    #     persona name: "Kit", voice: "warm, concise, never pushy"
    #     playbook     { product_brief "..." }
    #     capabilities { register Concierge::Tools::RecallTool, access: :read }
    #     authority    { default :autonomous }
    #   end
    #
    #   c.agent(:csm).authority.level_for("message.outreach")  # => :autonomous
    #
    # Reading an agent that was never declared returns nil, *except* for +:csm+:
    # a host that only ever used the top-level blocks is the CSM, so it folds
    # into an implicit +:csm+ agent (§10.9 back-compat) and keeps working.
    def agent(slug = DEFAULT_AGENT_SLUG, &block)
      slug = slug.to_sym

      if block
        found = (@agents[slug] ||= Spike::Agent.new(slug))
        found.instance_eval(&block)
        return found
      end

      @agents[slug] || (slug == DEFAULT_AGENT_SLUG ? implicit_csm_agent : nil)
    end

    # Every declared agent, in declaration order. A host that declared none gets
    # the implicit CSM, so callers never have to special-case "no agents yet".
    def agents
      @agents.any? ? @agents.values : [ implicit_csm_agent ]
    end

    def agent_declared?(slug)
      @agents.key?(slug.to_sym)
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

    private

    # The migration bridge (§10.9): the existing top-level blocks *are* the CSM.
    # Built lazily and memoized so `config.agent(:csm).playbook` reads back the
    # very same Playbook object `config.playbook` returns — no copy to drift.
    def implicit_csm_agent
      @implicit_csm_agent ||= begin
        top_level_playbook     = @playbook
        top_level_capabilities = capabilities
        # draft_and_review was "stage the one outreach action for a human"; that
        # is exactly :human_approval on the message action class.
        outreach_level = @draft_and_review ? :human_approval : :autonomous

        Spike::Agent.new(DEFAULT_AGENT_SLUG).tap do |a|
          a.instance_variable_set(:@playbook, top_level_playbook) if top_level_playbook
          a.instance_variable_set(:@capabilities, top_level_capabilities)
          a.instance_variable_set(:@model, @default_model)
          a.authority { action "message.outreach", outreach_level }
        end
      end
    end
  end
end
