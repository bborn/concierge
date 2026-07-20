module Concierge
  # An audit row for every message Concierge sends (or would have sent). Doubles
  # as the frequency-cap ledger: governance counts recent rows per subject.
  class ChannelDelivery < ApplicationRecord
    include SubjectScoped

    scope :of_kind, ->(kind) { where(kind: kind.to_s) }
  end
end
