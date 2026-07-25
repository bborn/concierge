module Concierge
  # Per-subject outreach preferences the customer controls ("email me less").
  # Phase 4 lands the frequency lever so the set_outreach_preference tool has a
  # real target; Phase 6 governance reads and extends it (opt-out, quiet hours).
  class OutreachPreference < ApplicationRecord
    include SubjectScoped

    FREQUENCIES = %w[off less normal more].freeze

    validates :frequency, inclusion: { in: FREQUENCIES }

    # The subject's preferences, defaulted (unsaved) when they've never set any.
    # Takes a Scope or a bare Subject and always keys by the subject: this is one
    # of the two tables design §10.1 deliberately leaves out of the agent
    # dimension, because "email me less" is the customer's word to the company,
    # not to one business function.
    def self.for(subject)
      find_or_initialize_by(Scope.subject_key(subject))
    end
  end
end
