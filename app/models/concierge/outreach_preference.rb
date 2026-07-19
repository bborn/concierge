module Concierge
  # Per-subject outreach preferences the customer controls ("email me less").
  # Phase 4 lands the frequency lever so the set_outreach_preference tool has a
  # real target; Phase 6 governance reads and extends it (opt-out, quiet hours).
  class OutreachPreference < ApplicationRecord
    FREQUENCIES = %w[off less normal more].freeze

    validates :frequency, inclusion: { in: FREQUENCIES }

    def self.for_subject(subject)
      find_or_initialize_by(
        subject_type: subject.grain.to_s,
        subject_id:   subject.id.to_s
      )
    end
  end
end
