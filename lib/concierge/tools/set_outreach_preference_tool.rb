module Concierge
  module Tools
    # Honors "email me less" (and friends) said in chat: persists the customer's
    # outreach cadence so Phase 6 governance can respect it. Write-access, but
    # non-destructive — it only adjusts a preference row.
    class SetOutreachPreferenceTool < Concierge::Capability::NativeTool
      description "Set how often this account wants to hear from us. " \
                  "Use when the customer asks to be contacted more or less."
      param :frequency,
        desc: "One of: off, less, normal, more.",
        required: true

      def name
        "set_outreach_preference"
      end

      def perform(frequency:)
        frequency = frequency.to_s
        unless Concierge::OutreachPreference::FREQUENCIES.include?(frequency)
          return { error: "frequency must be one of #{Concierge::OutreachPreference::FREQUENCIES.join(', ')}" }
        end

        Concierge::OutreachPreference.for(subject).update!(frequency: frequency)
        { ok: true, frequency: frequency }
      end
    end
  end
end
