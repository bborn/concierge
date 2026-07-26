module Concierge
  # Static host knowledge the agent needs: what the product is, what "engaged"
  # means, and who the agent is. Configured through a block DSL:
  #
  #   config.playbook do
  #     product_brief "Acme helps teams ship changelogs."
  #     goals "Get each account to publish their first changelog."
  #     account_types :brand, :creator
  #     engagement_signal(:has_paid_plan) { |s| s[:plan] != "free" }
  #     persona name: "Kit", voice: "warm, concise, never pushy"
  #   end
  #
  # As with AccountAdapter, each setter doubles as a reader when called bare.
  class Playbook
    extend DSL

    Persona = Struct.new(:name, :avatar, :voice, keyword_init: true)

    # A neutral default so the agent has a usable voice out of the box. Hosts
    # override it by declaring their own persona. No name — the run falls back to
    # a generic "customer success manager" role until the host names its agent.
    DEFAULT_PERSONA = Persona.new(
      name: nil, avatar: nil, voice: "warm, concise, and helpful, never pushy"
    ).freeze

    def initialize
      @engagement_signals = {}
      @account_types      = []
    end

    dsl_value :product_brief
    dsl_value :goals

    # The kinds of account this playbook knows about. Declaring a type twice
    # declares it once: +Concierge::Agent#playbook+ memoizes, so a host whose
    # initializer re-runs on every code reload would otherwise get one more copy
    # of its type list per reload.
    def account_types(*names)
      @account_types |= names.flatten.map(&:to_sym) if names.any?
      @account_types
    end

    # A named engagement signal — a lambda over a Subject whose value feeds the
    # account-state Snapshot. Registration order is preserved and drives the
    # Snapshot's (deterministic) order.
    def engagement_signal(name, &block)
      @engagement_signals[name.to_sym] = block
    end

    def engagement_signals
      @engagement_signals
    end

    # The agent's identity. Called with arguments, it sets the persona; called
    # bare, it returns the configured persona or the neutral DEFAULT_PERSONA.
    def persona(name: nil, avatar: nil, voice: nil)
      @persona = Persona.new(name: name, avatar: avatar, voice: voice) if name || avatar || voice
      @persona || DEFAULT_PERSONA
    end

    # True only when the host declared its own persona (not the default).
    def persona_configured?
      !@persona.nil?
    end
  end
end
