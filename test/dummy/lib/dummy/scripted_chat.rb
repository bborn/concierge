module Dummy
  # Offline stand-in for a RubyLLM chat, mirroring the fluent surface
  # Concierge::Run drives. Unlike the test FakeChat this isn't scripted per
  # call — it just answers, so the dummy app works without an API key.
  #
  # It reads the Snapshot block out of the system prompt it was handed, so the
  # canned reply is at least *about* the right account: with no key there is no
  # model to notice that Acme has never published a changelog, so the stand-in
  # notices instead. Setting ANTHROPIC_API_KEY replaces all of this with a real
  # model over the very same prompt.
  class ScriptedChat
    Reply = Struct.new(:content, :tool_calls, :input_tokens, :output_tokens, keyword_init: true)

    def initialize
      @instructions = +""
    end

    def with_instructions(text, replace: false)
      @instructions = replace ? text.to_s.dup : "#{@instructions}\n#{text}"
      self
    end

    def with_temperature(_value) = self
    def with_context(_context)   = self
    def with_params(**)          = self
    def with_tools(*)            = self

    def ask(prompt)
      reply = Reply.new(
        content: answer_for(prompt.to_s), tool_calls: [],
        input_tokens: 320, output_tokens: 48
      )
      yield reply if block_given?
      reply
    end

    private

    # Deliberately dumb keyword matching. It exists so a keyless demo shows the
    # loop working, not so it looks clever — and every branch is something the
    # signed-in user can then go and check in the product.
    def answer_for(prompt)
      case prompt
      when /publish|changelog|first entry|how do i/i then publishing_answer
      when /upgrade|plan|pricing|invoice|billing/i   then billing_answer
      when /human|person|support|help me/i           then handoff_answer
      else                                                proactive_answer
      end
    end

    def publishing_answer
      if published.zero?
        "Publishing takes about a minute: open Changelog, hit New entry, write what " \
        "shipped, then Publish. #{draft_note}You're on the #{plan} plan, so it goes out " \
        "to everyone following your changelog. Want to do it now?"
      else
        "You've published #{published} #{'entry'.pluralize(published)} already — nice. " \
        "The next one is the same flow: Changelog → New entry → Publish."
      end
    end

    def billing_answer
      "Plan changes go through our team rather than happening automatically. Use " \
      "\"Request a plan change\" on the Account page and I'll put it in front of " \
      "someone; you're on #{plan} today."
    end

    def handoff_answer
      "Of course — \"Talk to a human\" on the Account page hands this thread to a " \
      "person on our team, and I'll step back until they're done."
    end

    def proactive_answer
      if published.zero?
        "You haven't published a changelog entry yet, and that's the one thing that " \
        "makes the rest of Acme click. #{draft_note}Want me to walk you through it?"
      else
        "Things look healthy — #{published} #{'entry'.pluralize(published)} published " \
        "on the #{plan} plan. Shout if you want a hand with the next one."
      end
    end

    def draft_note
      drafts.positive? ? "You already have #{drafts} draft waiting. " : ""
    end

    # Signal values as the Snapshot renders them ("- published_changelogs: 0").
    def signal(name, default = nil)
      @instructions[/^- #{name}: (.+)$/, 1]&.strip || default
    end

    def published = signal("published_changelogs", "0").to_i
    def drafts    = signal("draft_changelogs", "0").to_i
    def plan      = signal("plan", "current")
  end
end
