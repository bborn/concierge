module Concierge
  # A drafted message awaiting human review. Only used when the optional
  # draft_and_review mode is enabled; otherwise Concierge delivers autonomously.
  class OutboxItem < ApplicationRecord
    include AgentScoped

    self.table_name = "concierge_outbox_items"

    STATES = %w[pending approved discarded].freeze

    validates :state, inclusion: { in: STATES }

    scope :pending, -> { where(state: "pending") }
  end
end
