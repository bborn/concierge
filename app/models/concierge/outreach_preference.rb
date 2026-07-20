module Concierge
  # Per-subject outreach preferences the customer controls ("email me less").
  # Phase 4 lands the frequency lever so the set_outreach_preference tool has a
  # real target; Phase 6 governance reads and extends it (opt-out, quiet hours).
  class OutreachPreference < ApplicationRecord
    include SubjectScoped

    FREQUENCIES = %w[off less normal more].freeze

    validates :frequency, inclusion: { in: FREQUENCIES }

    # The subject's preferences, defaulted (unsaved) when they've never set any.
    def self.for(subject)
      find_or_initialize_by(subject.key)
    end
  end
end
