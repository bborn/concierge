module Concierge
  # Scores accounts so scarce budget is spent on the highest-value ones first
  # (design §4.3). Scoring is host-configurable via config.priority (a lambda
  # over a Subject → numeric); the default treats every account equally.
  class PriorityService
    def self.score(subject)
      scorer = Concierge.config.priority
      scorer ? scorer.call(subject) : 0
    end

    # Highest score first; stable for equal scores. Items need not be Subjects —
    # pass a block to say where the Subject lives inside each item.
    def self.order(items)
      items.sort_by.with_index do |item, i|
        [ -score(block_given? ? yield(item) : item), i ]
      end
    end
  end
end
