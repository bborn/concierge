module Concierge
  # A drafted message awaiting human review. Only used when the optional
  # draft_and_review mode is enabled; otherwise Concierge delivers autonomously.
  class OutboxItem < ApplicationRecord
    self.table_name = "concierge_outbox_items"

    STATES = %w[pending approved discarded].freeze

    validates :state, inclusion: { in: STATES }

    scope :pending, -> { where(state: "pending") }
    scope :for_subject, ->(subject) {
      where(subject_type: subject.grain.to_s, subject_id: subject.id.to_s)
    }
  end
end
