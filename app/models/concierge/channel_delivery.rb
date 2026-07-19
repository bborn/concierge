module Concierge
  # An audit row for every message Concierge sends (or would have sent). Doubles
  # as the frequency-cap ledger: governance counts recent rows per subject.
  class ChannelDelivery < ApplicationRecord
    scope :for_subject, ->(subject) {
      where(subject_type: subject.grain.to_s, subject_id: subject.id.to_s)
    }
    scope :of_kind, ->(kind) { where(kind: kind.to_s) }
    scope :since, ->(time) { where(sent_at: time..) }
  end
end
