module Concierge
  # The per-agent authority envelope (design §10.5): what this agent may do on
  # its own, keyed by action class. Replaces the single global
  # +draft_and_review+ boolean, which staged exactly one action for the whole
  # engine.
  #
  #   authority do
  #     default                :human_approval
  #     action "money.refund", :human_execution
  #   end
  #
  # As everywhere else in the config DSL, a setter called bare is a reader:
  # +default+ returns the default level, +action("money.refund")+ returns the
  # level declared for that class (nil when none was).
  class Authority
    # :autonomous       — execute within caps, no per-action human gate
    # :human_approval   — agent proposes, human approves, the engine executes
    # :human_execution  — agent proposes, human approves *and* executes
    LEVELS = %i[autonomous human_approval human_execution].freeze

    # The action class every outbound message travels under. Named here because
    # it is the one class the engine itself dispatches today; hosts add their own
    # (record.update, money.refund, …) as §10.6's executors land.
    MESSAGE_OUTREACH = "message.outreach".freeze

    def initialize
      @default = :autonomous
      @actions = {}
    end

    def default(level = nil)
      @default = validate!(level) if level
      @default
    end

    def action(action_class, level = nil)
      key = action_class.to_s
      @actions[key] = validate!(level) if level
      @actions[key]
    end

    # The governing level for an action class: its own if declared, else the
    # agent's default. This is the one question the runtime asks.
    def level_for(action_class)
      @actions.fetch(action_class.to_s, @default)
    end

    def autonomous?(action_class)
      level_for(action_class) == :autonomous
    end

    # True when a human must both approve and perform the action itself.
    def human_execution?(action_class)
      level_for(action_class) == :human_execution
    end

    def actions
      @actions.dup
    end

    def to_h
      { default: @default, actions: actions }
    end

    private

    def validate!(level)
      level = level.to_sym
      return level if LEVELS.include?(level)

      raise Concierge::Error,
            "unknown authority level #{level.inspect} (expected one of #{LEVELS.inspect})"
    end
  end
end
