module Concierge
  # What the **customer** can do about a message, offered next to the words as
  # buttons — "Update payment method", "Yes, help me with that.", "Book a call".
  #
  # Not an authority *action class*. `message.outreach` and `record.plan_change`
  # (Concierge::Authority) are things the *agent* may or may not do, gated by its
  # envelope. This is host product surface: a link the customer follows, a canned
  # reply they send. Nothing here grants anybody permission to do anything.
  #
  # ## Who decides what buttons a message carries (docs/design/message-actions.md)
  #
  # Three parties, each doing only what it is authoritative about:
  #
  #   * The **host declares** the vocabulary, per agent — key, caption, and
  #     whatever its own surface needs to render the thing (an href, canned reply
  #     text, a confirm string). It owns its product, so it owns all of that.
  #   * The **engine advertises** the vocabulary in the run's prompt and carries
  #     the agent's selection. It never invents an offer and never reads the
  #     host's rendering attributes.
  #   * The **agent selects** by naming keys on a trailing line, exactly the way
  #     it cites the rules it applied. It is not asked to know what the host's
  #     product can do — it is told, one line each.
  #
  # So the model never authors a label, a URL or an action. Naming a key nobody
  # declared costs a missing button, not a fabricated one.
  #
  #   c.agent :billing do
  #     actions do
  #       offer :update_payment_method,
  #             label:    "Update payment method",
  #             use_when: "the card on file is expiring, missing, or has been declined",
  #             href:     "/account#payment"
  #     end
  #   end
  #
  # Declaration is **total, not cumulative** — the same rule every collection in
  # the config surface obeys (see Concierge::DSL): re-declaring a key replaces it
  # in place rather than appending, so a host's initializer re-running on every
  # code reload in development does not grow one copy of the vocabulary per
  # reload.
  class Actions
    # The machine-readable line the agent ends its reply with, naming the offers
    # it wants shown. Stripped from the reply before anything reaches a customer,
    # for the same reason Rules::CITATION_PREFIX is.
    PREFIX = "Actions-Offered:".freeze

    LINE = /^[ \t>*\-]*#{Regexp.escape(PREFIX)}[ \t]*(?<keys>.*)$/i

    # A key is a config identifier, not prose: word characters only, so a model
    # that answers with a sentence names nothing rather than half-matching.
    KEY = /\A[a-z0-9_]+\z/i

    # One declared offer. +attributes+ is whatever the host's own surface needs to
    # render it and is opaque here — the engine carries it back out untouched.
    Offer = Struct.new(:key, :label, :use_when, :attributes) do
      def to_payload
        { key: key, label: label }.merge(attributes || {})
      end

      # How the model is told this offer exists. Deliberately without the
      # rendering attributes: an href is not something the agent has any use for,
      # and showing it invites the model to quote a URL into its prose.
      def to_prompt
        line = "- #{key}: #{label}"
        line += " — offer this when #{use_when}" if use_when.to_s.strip != ""
        line
      end
    end

    Selection = Struct.new(:text, :keys, keyword_init: true)

    class << self
      # Pull the trailing +Actions-Offered:+ line out of a reply and return the
      # reply *without* it plus the keys it named. A reply with no line names
      # nothing — silence is not a claim, exactly as with rule citations.
      #
      # Always run, even for an agent with an empty vocabulary: a model that
      # emits the line unprompted must not have it reach a customer.
      def extract(reply_text)
        text = reply_text.to_s
        keys = text.scan(LINE).flatten.flat_map { |list| parse_keys(list) }.uniq

        Selection.new(text: strip(text), keys: keys)
      end

      private

      def parse_keys(list)
        return [] if list.to_s.strip.match?(/\A(none|n\/a|-)?\z/i)

        list.split(/[\s,]+/).map(&:strip).select { |key| key.match?(KEY) }.map(&:downcase)
      end

      def strip(text)
        text.gsub(LINE, "").sub(/\s+\z/, "")
      end
    end

    def initialize
      @offers = []
    end

    # Declare an offer. +label+ is the caption the host wants on the button;
    # +use_when+ is the one line the agent is given about when it applies; every
    # other keyword travels through to the host's renderer untouched.
    def offer(key, label:, use_when: nil, **attributes)
      entry = Offer.new(key.to_s, label, use_when, attributes)
      found = @offers.index { |o| o.key == entry.key }

      found ? @offers[found] = entry : @offers << entry
      self
    end

    def clear
      @offers.clear
      self
    end

    def entries = @offers.dup
    def keys    = @offers.map(&:key)
    def any?    = @offers.any?
    def empty?  = @offers.empty?

    def [](key) = @offers.find { |o| o.key == key.to_s }

    # The declared offers for these keys, in **declaration** order and without
    # duplicates. The host decided what order its buttons read in; the agent
    # decided which of them apply, and the order it happened to list them in is
    # not a product decision.
    def resolve(selected)
      wanted = Array(selected).map(&:to_s)
      @offers.select { |offer| wanted.include?(offer.key) }
    end

    # Keys the agent named that were never declared. Not an error — but exactly
    # the kind of thing an operator should be able to see, so it is recorded
    # rather than dropped (cf. Result#unknown_rule_ids).
    def unknown(selected)
      Array(selected).map(&:to_s).uniq - keys
    end

    # How the vocabulary renders into the run's prompt. Nil when there is none,
    # so the prompt simply has no section rather than an empty heading.
    def to_prompt
      return if empty?

      [
        "Actions the customer can take about this message. These are the host " \
        "product's own buttons; you choose which apply, you never invent one.",
        @offers.map(&:to_prompt).join("\n"),
        "End your reply with a final line `#{PREFIX} <keys>` naming the ones to " \
        "show (or `#{PREFIX} none`). Use the keys exactly; anything not listed " \
        "above shows nothing. That line is stripped before the customer sees " \
        "your reply, and offering an action is not the same as doing it."
      ].join("\n\n")
    end
  end
end
