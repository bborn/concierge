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

    # --- Rules (Phase 10, §10.2) ---

    # How many `active` rules may be in force for one scope at once. Hitting the
    # cap *blocks* activation and demands a consolidation — it never silently
    # truncates the rule set. Nil uses Concierge::Rules::DEFAULT_ACTIVE_CAP.
    attr_accessor :active_rule_cap

    # Optional callable(correction_text) -> String | Hash that drafts a rule body
    # from a human correction. The default is lexical and deterministic (first
    # concern, normalized), which is what keeps the whole write path runnable with
    # no model and no network; this is the seam where a host puts a real
    # generalization pass. It drafts only — nothing here can activate a rule.
    attr_accessor :rule_generalizer

    # Optional callable(rule) invoked when a rule proposal (or a retirement
    # proposal) is created, so a host can post the card wherever its humans are —
    # Slack Block Kit, email, an internal queue. Without one the card still lives
    # on /concierge/admin/rules, so this is optional rather than a required
    # dependency on a chat transport. A raising notifier never loses the rule.
    attr_accessor :rule_proposal_notifier

    # Optional callable(subject) -> [segment names] naming the segments an account
    # belongs to, so a rule can apply to "EU accounts" without naming each one.
    # Without it there are no segments and segment-scoped rules never apply.
    attr_accessor :segments_for

    # --- Proposals (Phase 10, §10.5/§10.6) ---

    # How long a proposal stays approvable. Nil (the default) means proposals do
    # not expire: silently retiring a host's staged drafts on upgrade would be a
    # surprise, and a proposal that never expires is exactly today's behaviour for
    # the outbox this generalizes. Set it and Concierge::SweepJob retires
    # unapproved proposals past their date — an approval nobody acted on for a
    # month should have to be re-drafted against current state, not executed.
    attr_accessor :proposal_ttl

    # Optional callable(proposal) invoked when a proposal is created, so a host can
    # post the approval card wherever its humans are. Without one the card still
    # lives on /concierge/admin/proposals. A raising notifier never loses the
    # proposal — the same rule as rule_proposal_notifier.
    attr_accessor :proposal_notifier

    # --- Admin surface (Phase 9) ---

    # Callable(controller) -> truthy to permit admin access. Nil = deny (the admin
    # fails closed rather than shipping an open dashboard).
    attr_accessor :authenticate_admin

    # Callable(controller) -> the identity of the human driving the admin, used as
    # the approver when a rule is activated. The engine cannot know the host's
    # session shape, so it asks. Without it, the maker-checker gate refuses rather
    # than inventing an approver.
    attr_accessor :admin_actor

    def initialize
      @chat_model_name  = "Chat"
      @draft_and_review = false
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

    # Where the host says how an action class it owns is performed, and what that
    # action assumed about the world (§10.6/§10.8). The engine registers its own
    # +message.*+ executor here, so a host can override it.
    #
    #   config.proposals do
    #     execute("record.update") { |proposal, scope| ... }
    #     precondition("record.update") { |scope| { plan: scope.subject[:plan] } }
    #   end
    def proposals(&block)
      @proposals ||= Proposal::Registry.new
      @proposals.instance_eval(&block) if block
      @proposals
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
        found = (@agents[slug] ||= Agent.new(slug))
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

    # The migration bridge (§10.9): a host that never called +config.agent+ *is*
    # the CSM, so the top-level blocks are read as that agent's slots. Every slot
    # reads through to the Configuration at call time rather than being copied at
    # build time, so a host that keeps configuring after the first read (an
    # initializer sets +draft_and_review+ late, say) can never see a stale
    # envelope — the staleness the step-0 spike flagged in its §D5.
    class ImplicitCsmAgent < Agent
      def initialize(config)
        super(DEFAULT_AGENT_SLUG)
        @config = config
      end

      def playbook(&block)
        book = @config.playbook || (@playbook ||= Concierge::Playbook.new)
        book.instance_eval(&block) if block
        book
      end

      def capabilities(&block)
        @config.capabilities(&block)
      end

      # draft_and_review was "stage the one outreach action for a human"; that is
      # exactly :human_approval on the message action class.
      def authority(&block)
        envelope = super
        envelope.action(Authority::MESSAGE_OUTREACH,
                        @config.draft_and_review ? :human_approval : :autonomous)
        envelope
      end
    end

    private

    def implicit_csm_agent
      @implicit_csm_agent ||= ImplicitCsmAgent.new(self)
    end
  end
end
