module Concierge
  class Rules
    # Conflict-check-at-write-time (design §10.2). When a rule is proposed, look
    # at the active rules that would share a prompt with it and flag the two ways
    # a rule set rots:
    #
    #   :duplicate      the same instruction said twice — prompt bloat, and the
    #                   thing the active-rule cap exists to push back on
    #   :contradiction  the same concern with opposite polarity ("always attach
    #                   the invoice" vs "never attach the invoice") — the failure
    #                   that makes an agent's behaviour a coin flip
    #
    # This is deliberately a lexical check, not a semantic one. It runs inline on
    # every propose, in CI, with no model call, and it is honest about what it is:
    # a *surfacing* mechanism. Its output is shown to a human, who resolves it —
    # nothing here decides anything. A host with a model to spare can layer a
    # semantic check on top of the same seam (+config.rule_generalizer+ already
    # drafts the body); the point of this one is that it always runs.
    class ConflictCheck
      # Overlap above this, with matching polarity, reads as the same instruction.
      DUPLICATE_THRESHOLD = 0.7

      # Overlap above this, with *opposing* polarity, reads as a contradiction.
      # Lower on purpose: "never send before 9am" and "send before 9am" share
      # fewer words than two paraphrases do, and a missed contradiction is far
      # more expensive than a false positive a human waves off.
      CONTRADICTION_THRESHOLD = 0.45

      NEGATIONS = %w[
        never not no dont don't doesnt doesn't cannot cant can't avoid without
        stop refrain neither nor
      ].freeze

      # Modality is polarity, not subject matter. "Always quote a date" and "never
      # quote a date" are *about the same thing*; leaving "always" in the content
      # set while stripping "never" would make the pair look less alike than it is,
      # and hide the contradiction the check exists to find.
      MODALS = %w[always must should shall ought ever only].freeze

      # Words that carry no subject matter. Kept short: an aggressive stopword
      # list makes short rules look identical to each other.
      STOPWORDS = %w[
        a an the this that these those and or but if then than for to of in on at
        by with from as is are was were be been being do does did doing have has
        had you your yours their they them it its we our us i me my
      ].freeze

      def initialize(rule)
        @rule = rule
      end

      # Serialized with string keys because it lands in the rule's provenance
      # JSON and has to survive the round trip unchanged.
      def conflicts
        candidates.filter_map do |other|
          kind = classify(other)
          next unless kind

          { "rule_id" => other.id, "kind" => kind.to_s,
            "similarity" => similarity(other).round(2),
            "body" => other.body.to_s.strip }
        end
      end

      private

      def candidates
        AgentRule.active.shares_prompt_with(@rule).where.not(id: @rule.id)
      end

      def classify(other)
        score = similarity(other)

        if negated?(@rule.body) == negated?(other.body)
          :duplicate if score >= DUPLICATE_THRESHOLD
        elsif score >= CONTRADICTION_THRESHOLD
          :contradiction
        end
      end

      def similarity(other)
        mine   = content_words(@rule.body)
        theirs = content_words(other.body)
        return 0.0 if mine.empty? || theirs.empty?

        (mine & theirs).size.to_f / (mine | theirs).size
      end

      # Content words only: polarity and modality are compared separately, so
      # "always attach the invoice" and "never attach the invoice" must come out as
      # the *same* subject matter for the contradiction to be visible at all.
      def content_words(body)
        words(body) - NEGATIONS - MODALS - STOPWORDS
      end

      def negated?(body)
        words(body).intersect?(NEGATIONS)
      end

      def words(body)
        body.to_s.downcase.scan(/[a-z']+/).uniq
      end
    end
  end
end
