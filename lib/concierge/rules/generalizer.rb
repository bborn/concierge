module Concierge
  class Rules
    # Turns a verbatim human correction into a candidate rule (design §10.2).
    #
    # Two jobs, both deliberately dumb by default:
    #
    #   .behavioral?  is this correction an instruction about how to behave (-> a
    #                 rule, gated) or a fact about this relationship (-> memory)?
    #   .call         draft the single-concern instruction bullet.
    #
    # The default implementation is lexical and deterministic, which is what lets
    # the whole write path run in CI with no model and no network. A host that
    # wants a real generalization pass sets +config.rule_generalizer+ to a
    # callable — that is the seam, and it is the only place a model belongs on
    # this path. Nothing here can promote a rule either way: the output is always
    # a +proposed+ row waiting for a human.
    class Generalizer
      # Language that marks a correction as an instruction rather than an
      # observation. Deliberately conservative: mis-routing a *fact* into the rule
      # pipeline costs a human a tap to reject, but mis-routing an *instruction*
      # into memory loses the gate — so the ambiguous case defaults to a fact,
      # which is exactly where corrections have always gone.
      INSTRUCTION_MARKERS = [
        /\balways\b/i, /\bnever\b/i, /\bdon'?t\b/i, /\bdo not\b/i, /\bstop\b/i,
        /\bmake sure\b/i, /\bbe sure\b/i, /\bremember to\b/i, /\bfrom now on\b/i,
        /\bgoing forward\b/i, /\bin (the )?future\b/i, /\bavoid\b/i,
        /\bmust not\b/i, /\bmust\b/i, /\bshould(n'?t)?\b/i, /\bno longer\b/i,
        /\bbefore you\b/i, /\bwhenever\b/i, /\beach time\b/i, /\bonly ever\b/i
      ].freeze

      # Editorial noise an operator types before the actual correction.
      PREFIXES = /\A\s*(operator|note|fyi|heads up|reminder|correction)\s*[:\-]\s*/i

      MAX_BODY = 240

      class << self
        # The heuristic half of "Learning becomes an intake router." An explicit
        # operator choice always wins over this — see Learning.capture(kind:).
        def behavioral?(content)
          text = content.to_s
          INSTRUCTION_MARKERS.any? { |marker| text.match?(marker) }
        end

        # Draft the rule body from a correction. Returns a Hash so a host's
        # generalizer can also propose a predicate/enforcement, not just text.
        def call(content)
          hook = Concierge.config.rule_generalizer
          return normalize(hook.call(content)) if hook

          { "body" => single_concern(content), "enforcement" => "advisory" }
        end

        # The dreaming job's merge draft. The default keeps the *shortest* body —
        # the most general statement of the shared concern — and the evidence on
        # the proposal lists every original verbatim, so nothing is lost and a
        # human edits the wording before it goes live.
        def merge(bodies)
          bodies = Array(bodies).map { |body| body.to_s.strip }.reject(&:empty?)
          return { "body" => "", "enforcement" => "advisory" } if bodies.empty?

          hook = Concierge.config.rule_generalizer
          return normalize(hook.call(bodies.join(" "))) if hook

          { "body" => bodies.min_by(&:length), "enforcement" => "advisory" }
        end

        private

        # One concern, one bullet: strip the operator's framing, keep the first
        # sentence, and cap the length. A correction that carries two instructions
        # becomes one rule about the first — the human editing the card is what
        # splits it, and a cap that forces generalization is the whole point.
        def single_concern(content)
          text = content.to_s.gsub(PREFIXES, "").squish
          first = text.split(/(?<=[.!?])\s+/).first.to_s
          first = text if first.empty?
          first = "#{first[0, MAX_BODY].rstrip}…" if first.length > MAX_BODY
          first
        end

        def normalize(drafted)
          case drafted
          when Hash
            drafted.transform_keys(&:to_s).tap do |hash|
              hash["body"] = hash["body"].to_s.squish
              hash["enforcement"] ||= "advisory"
            end
          else
            { "body" => drafted.to_s.squish, "enforcement" => "advisory" }
          end
        end
      end
    end
  end
end
