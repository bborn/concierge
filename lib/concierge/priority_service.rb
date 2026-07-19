module Concierge
  # Scores accounts so scarce budget is spent on the highest-value ones first
  # (design §4.3). Scoring is host-configurable via config.priority (a lambda
  # over a Subject → numeric); the default treats every account equally.
  class PriorityService
    def self.score(subject)
      scorer = Concierge.config.priority
      scorer ? scorer.call(subject) : 0
    end

    # Highest score first; stable for equal scores.
    def self.order(subjects)
      subjects.sort_by.with_index { |subject, i| [ -score(subject), i ] }
    end
  end
end
