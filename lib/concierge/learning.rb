module Concierge
  # The learning loop (design §0.9): when a human takes over — writing a message,
  # editing a draft, overriding an outreach — that content is captured as
  # high-confidence, human-sourced memory. Because ContextStore.top_of_mind
  # weights human ahead of agent, these corrections steer future runs, so the
  # same mistake isn't repeated.
  class Learning
    def self.capture(subject, content:, category: "operator_note", pinned: true)
      return if content.to_s.strip.empty?

      ContextStore.new.remember(
        subject,
        body:     content,
        category: category,
        source:   :human,
        pinned:   pinned
      )
    end
  end
end
