module Concierge
  # A business function as a first-class, host-declared configuration object
  # (design §10.1). The customer success manager is no longer *the* engine; it is
  # agent #1 (+:csm+), and lead-qualification, billing, or disputes agents are the
  # same engine with a different charter, tools, and authority.
  #
  #   c.agent :billing do
  #     persona name: "Bill", voice: "precise and factual"
  #     model   "claude-haiku-4-5-20251001"
  #
  #     playbook do
  #       product_brief "..."
  #       engagement_signal(:plan) { |s| s[:plan] }
  #     end
  #
  #     capabilities do
  #       register Concierge::Tools::RecallTool, access: :read
  #     end
  #
  #     authority do
  #       default                :human_approval
  #       action "money.refund", :human_execution
  #     end
  #
  #     enabled true
  #   end
  #
  # The six slots of design §10.1 map onto this object as:
  #
  #   1 identity/persona/model  -> #persona (via the agent's Playbook), #model
  #   2 charter                 -> #playbook
  #   3 tool scope              -> #capabilities
  #   4 authority envelope      -> #authority
  #   5 memory namespace        -> #slug (see Concierge::Scope; NOT separately
  #                                configurable — the namespace *is* the slug)
  #   6 kill switch             -> #enabled
  class Agent
    extend DSL

    attr_reader :slug

    def initialize(slug)
      @slug    = slug.to_sym
      @enabled = true
    end

    # Slot 1b — the model this agent runs on. Nil means "the house default":
    # callers resolve it as +agent.model || config.default_model+, so an agent
    # only names one when it needs a cheaper or stronger model than the default.
    dsl_value :model

    # Slot 1a — identity. Persona lives on the Playbook (it always has), but
    # hoisting it to the top of the agent block is what makes two agent blocks
    # read as two people rather than two config hashes.
    def persona(name: nil, avatar: nil, voice: nil)
      playbook.persona(name: name, avatar: avatar, voice: voice)
    end

    # Slot 2 — the charter: product brief, goals, engagement signals.
    def playbook(&block)
      @playbook ||= Concierge::Playbook.new
      @playbook.instance_eval(&block) if block
      @playbook
    end

    # Slot 3 — least-privilege tool scope, per function. An off-scope tool is not
    # registered here, so it never reaches +chat.with_tools+ — it does not exist
    # in this agent's loop rather than existing and erroring.
    def capabilities(&block)
      @capabilities ||= Concierge::Capability::Registry.new
      @capabilities.instance_eval(&block) if block
      @capabilities
    end

    # Slot 4 — the authority envelope, per action class.
    def authority(&block)
      @authority ||= Authority.new
      @authority.instance_eval(&block) if block
      @authority
    end

    # This agent's **effective** authority on an action class — the one question
    # the runtime should ever ask, because it folds in the legacy global flag.
    #
    # +config.draft_and_review+ is sugar for ":human_approval on the message
    # action class" (§10.5) and only ever *tightens*: a host that flips it on
    # while also declaring agents must not silently get autonomous sends back, and
    # it must not loosen an agent that already gates harder. Reading
    # +authority.level_for+ directly skips that, which is how the staging decision
    # and the proposal's gate came to disagree.
    def level_for(action_class)
      level = authority.level_for(action_class)
      return level unless action_class.to_s == Authority::MESSAGE_OUTREACH
      return level unless Concierge.config.draft_and_review

      level == :autonomous ? :human_approval : level
    end

    def autonomous?(action_class)
      level_for(action_class) == :autonomous
    end

    # Slot 6 — the kill switch. Checked at run start and again at proposal
    # execution (§10.6), so ops can halt one function without a deploy.
    def enabled(value = nil)
      @enabled = !!value unless value.nil?
      @enabled
    end
    alias enabled? enabled

    # Slot 5 — the memory namespace. Deliberately *not* configurable: an agent's
    # namespace is its slug, and the only other namespace is the reserved
    # Scope::SHARED one. A second, settable identifier would only ever be a way
    # to alias two agents onto one memory pool — the exact cross-function
    # contamination §10.3 exists to prevent.
    def memory_namespace
      slug.to_s
    end

    def to_s
      "#<Concierge::Agent #{slug}>"
    end
  end
end
