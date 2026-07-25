module Concierge
  # The learning loop (design §0.9): when a human takes over — writing a message,
  # editing a draft, overriding an outreach — that content is captured as
  # high-confidence, human-sourced memory. Because ContextStore.top_of_mind
  # weights human ahead of agent, these corrections steer future runs, so the
  # same mistake isn't repeated.
  #
  # The correction lands in the namespace of the agent whose thread was taken
  # over — steering that business function, not every one of them. (§10.2 splits
  # generalized behavioral corrections out into versioned Rules; that is step 2.)
  class Learning
    def self.capture(scope, content:, category: "operator_note", pinned: true)
      return if content.to_s.strip.empty?

      ContextStore.new.remember(
        scope,
        body:     content,
        category: category,
        source:   :human,
        pinned:   pinned
      )
    end
  end
end
