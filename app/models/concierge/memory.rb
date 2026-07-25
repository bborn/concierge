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
    include AgentScoped

    TIERS   = %w[account subject].freeze
    SOURCES = %w[agent human].freeze

    validates :tier, inclusion: { in: TIERS }
    validates :source, inclusion: { in: SOURCES }

    scope :active,      -> { where(active: true) }
    scope :by_category, ->(category) { where(category: category) }
  end
end
