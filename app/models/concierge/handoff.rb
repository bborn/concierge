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

    # ...and the same for the handback. Seizing was attributable and releasing was
    # not, which had the audit trail backwards at the sharper end: releasing is
    # what re-enables autonomous proactive outbound for this (agent, subject) —
    # Concierge::Run suppresses proactive runs only while a handoff is active — so
    # "who decided the human was done" is at least as consequential as "who took
    # it over", and on a real desk it is routinely a different person.
    #
    # Conditional, because an active handoff has nobody to name yet. Rows released
    # before the column existed keep a null; nothing re-saves them.
    validates :released_by, presence: true, if: :released?

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

    # Hand the thread back. +by:+ is required for the reason +seize!+'s +operator:+
    # is: a host that cannot say who is acting should be told so at the call site
    # rather than have the engine record an unattributed handback. The engine's
    # endpoint passes config.operator_actor's answer (Concierge::ScopedEndpoint);
    # a host calling this from its own button answers for that seat.
    #
    # Each seize/release cycle is its own row — +seize!+ only reuses a handoff
    # that is still active — so a thread taken and handed back three times keeps
    # three attributable pairs without a second table.
    def release!(by:)
      update!(state: "released", released_at: Time.current, released_by: by)
    end

    def active?
      state == "active"
    end

    def released?
      state == "released"
    end
  end
end
