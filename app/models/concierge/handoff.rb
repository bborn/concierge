module Concierge
  # Human takeover of an account's thread. Control is takeover, not gating: while
  # a handoff is active, autonomous proactive sends for that subject are
  # suppressed (design §0.8). Takeover content feeds the learning loop (§0.9).
  class Handoff < ApplicationRecord
    STATES = %w[active released].freeze

    validates :state, inclusion: { in: STATES }

    scope :active, -> { where(state: "active") }

    def self.active_for(subject)
      active.find_by(subject_type: subject.grain.to_s, subject_id: subject.id.to_s)
    end

    # Start a takeover (idempotent — returns the existing active handoff if any).
    def self.seize!(subject, operator:)
      active_for(subject) || create!(
        subject_type: subject.grain.to_s,
        subject_id:   subject.id.to_s,
        operator:     operator,
        state:        "active",
        seized_at:    Time.current
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
