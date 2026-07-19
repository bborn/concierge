module Concierge
  # Durable, per-account memory the agent (and humans) read and write. This is
  # the CRM substrate: what the agent has learned, plus human-authored notes and
  # takeover corrections. +source+ distinguishes agent- from human-authored rows
  # so human signal can be weighted ahead of the agent's own (see the learning
  # loop, Phase 8).
  #
  # NOTE: deliberately NO `validates :body, presence: true`. The agent may write
  # sparse notes through the tool loop, and a persistence trap here would raise
  # mid-run. Keep validations off body.
  class Memory < ApplicationRecord
    TIERS   = %w[account subject].freeze
    SOURCES = %w[agent human].freeze

    validates :tier, inclusion: { in: TIERS }
    validates :source, inclusion: { in: SOURCES }

    scope :active,      -> { where(active: true) }
    scope :pinned,      -> { where(pinned: true) }
    scope :by_category, ->(category) { where(category: category) }
    scope :recent,      ->(limit = 20) { order(updated_at: :desc).limit(limit) }
    scope :account_tier, -> { where(tier: "account") }
    scope :subject_tier, -> { where(tier: "subject") }

    # All rows belonging to a Subject (matched on the polymorphic-ish key pair).
    scope :for_subject, ->(subject) {
      where(subject_type: subject.grain.to_s, subject_id: subject.id.to_s)
    }
  end
end
