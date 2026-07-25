module Concierge
  # The learning loop (design §0.9), now an **intake router** (§10.2).
  #
  # When a human takes over — writing a message, editing a draft, overriding an
  # outreach — that content is captured. Two different things arrive through this
  # one door, and Phase 10 stops conflating them:
  #
  #   a relationship fact         "renewal is in March"
  #     -> ContextStore.remember, exactly as before: human-sourced, pinned, and
  #        weighted ahead of the agent's own notes in the next prompt.
  #
  #   a behavioral correction     "never quote a delivery date without checking"
  #     -> *also* stored verbatim (the correction is the evidence), and then an
  #        out-of-band generalizer job drafts a versioned Rule from it, which
  #        lands `proposed` and waits for a human tap. Never active on capture.
  #
  # Routing is by explicit operator choice when one is available (+kind:+), and by
  # heuristic otherwise. The heuristic defaults to *fact*, so an ambiguous
  # correction lands where corrections have always landed rather than sliding into
  # a pipeline the operator didn't ask for.
  #
  # The correction lands in the namespace of the agent whose thread was taken
  # over, steering that business function and not every one of them.
  class Learning
    # What the capture became: the verbatim memory row, the route taken, and
    # whether a rule is being drafted from it.
    Intake = Struct.new(:memory, :route, :generalizing, keyword_init: true) do
      def rule_pending? = !!generalizing
    end

    # +kind:+ is the operator's explicit choice — :fact or :rule. Omitted, the
    # heuristic decides.
    def self.capture(scope, content:, category: "operator_note", pinned: true,
                     kind: nil, author: nil, provenance: {})
      return if content.to_s.strip.empty?

      memory = ContextStore.new.remember(
        scope,
        body:     content,
        category: category,
        source:   :human,
        pinned:   pinned
      )

      route = route_for(content, kind)
      generalize(memory, author: author, provenance: provenance) if route == :rule

      Intake.new(memory: memory, route: route, generalizing: route == :rule)
    end

    # Explicit choice wins; otherwise ask the generalizer whether this reads as an
    # instruction. Anything else is a fact.
    def self.route_for(content, kind)
      return kind.to_sym if kind && %i[fact rule].include?(kind.to_sym)

      Rules::Generalizer.behavioral?(content) ? :rule : :fact
    end

    # Out-of-band on purpose: drafting and conflict-checking a rule must not sit in
    # the request that captured the correction, and it must not be able to fail
    # that capture. The verbatim memory is already durable by the time this runs.
    def self.generalize(memory, author: nil, provenance: {})
      RuleGeneralizerJob.perform_later(
        memory.id,
        author:     author,
        provenance: provenance.transform_keys(&:to_s)
      )
    end

    private_class_method :route_for, :generalize
  end
end
