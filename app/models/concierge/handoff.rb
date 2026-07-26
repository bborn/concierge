module Concierge
  # Human takeover of an agent's thread with an account. Control is takeover, not
  # gating: while a handoff is active, autonomous proactive sends for that
  # (agent, subject) are suppressed (design §0.8). Takeover content feeds the
  # learning loop (§0.9).
  #
  # The takeover is per (agent, subject) — a behaviour change riding along with
  # the key change: a human holding the billing thread no longer silences the CSM.
  class Handoff < ApplicationRecord
    include AgentScoped

    STATES = %w[active released].freeze

    validates :state, inclusion: { in: STATES }

    # A takeover with nobody's name on it is not a takeover the product can
    # render: the customer is told "<operator> has taken this conversation over",
    # and an anonymous one reads as a bug or as nobody. The engine's endpoint
    # refuses before it gets here (Concierge::ScopedEndpoint#require_operator_identity!);
    # this is the same refusal for a host calling seize! itself.
    validates :operator, presence: true

    scope :active, -> { where(state: "active") }

    def self.active_for(scope)
      active.for_scope(scope).first
    end

    # Start a takeover (idempotent — returns the existing active handoff if any).
    def self.seize!(scope, operator:)
      active_for(scope) || create!(
        **Scope.coerce(scope).key,
        operator:  operator,
        state:     "active",
        seized_at: Time.current
      )
    end

    def release!
      update!(state: "released", released_at: Time.current)
    end

    def active?
      state == "active"
    end
  end
end
