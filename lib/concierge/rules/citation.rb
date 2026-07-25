module Concierge
  class Rules
    # The other half of per-run provenance (design §10.4): the agent tells us
    # which rules it actually applied, and we cross-check that claim against the
    # rules we actually injected.
    #
    # The reply ends with a machine-readable line:
    #
    #   Rules-Applied: 12, 14
    #   Rules-Applied: none
    #
    # +extract+ pulls the ids and returns the reply *without* that line, because
    # the citation is audit metadata and must never reach a customer. A reply with
    # no citation line yields no ids — silence is not a claim, and inventing one
    # would put words in the model's mouth in the audit trail.
    class Citation
      LINE = /^[ \t>*\-]*#{Regexp.escape(CITATION_PREFIX)}[ \t]*(?<ids>.*)$/i

      Extracted = Struct.new(:text, :rule_ids, keyword_init: true)

      class << self
        def extract(reply_text)
          text = reply_text.to_s
          ids  = text.scan(LINE).flatten.flat_map { |list| parse_ids(list) }.uniq

          Extracted.new(text: strip(text), rule_ids: ids)
        end

        # Ids the model cited that were never in its prompt. Not an error — but
        # exactly the kind of thing an operator should be able to see, so it is
        # recorded rather than dropped.
        def unknown(cited, injected)
          cited.map(&:to_i) - injected.map(&:to_i)
        end

        private

        def parse_ids(list)
          return [] if list.to_s.strip.match?(/\A(none|n\/a|-)?\z/i)

          list.scan(/\d+/).map(&:to_i)
        end

        def strip(text)
          text.gsub(LINE, "").sub(/\s+\z/, "")
        end
      end
    end
  end
end
