require "test_helper"

module Concierge
  # Who decides what buttons a message carries (docs/design/message-actions.md):
  # the host declares the vocabulary, the engine advertises it and carries the
  # keys back, the agent picks. Every test here is about one of those three
  # staying inside its own authority.
  class ActionsTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
    end

    # --- The vocabulary is the host's -----------------------------------------

    test "an offer carries the host's own caption and rendering attributes" do
      actions = declare

      offer = actions[:update_payment_method]
      assert_equal "Update payment method", offer.label
      assert_equal({ key: "update_payment_method", label: "Update payment method",
                     href: "/account#payment" }, offer.to_payload)
    end

    test "re-declaring a key replaces it rather than appending a second copy" do
      # A host's Concierge.configure runs again on every code reload in
      # development while the Configuration survives it, so an appending registry
      # would grow one copy of the vocabulary per reload — and render the button
      # five times.
      actions = Actions.new
      actions.offer :update_payment_method, label: "Update payment method", href: "/old"
      actions.offer :update_payment_method, label: "Update card",           href: "/new"

      assert_equal [ "update_payment_method" ], actions.keys
      assert_equal "/new", actions[:update_payment_method].attributes[:href]
    end

    test "resolve answers in declaration order, not the order the agent listed" do
      # The host decided what order its buttons read in. Which ones apply is the
      # agent's call; the sequence they appear in is not a decision it made.
      actions = declare

      assert_equal %w[update_payment_method yes_please],
                   actions.resolve(%w[yes_please update_payment_method]).map(&:key)
    end

    test "a key nobody declared resolves to nothing, and is reported" do
      actions = declare

      assert_empty actions.resolve(%w[wire_us_money])
      assert_equal %w[wire_us_money], actions.unknown(%w[wire_us_money update_payment_method])
    end

    # --- What the agent is told, and what it is not ---------------------------

    test "the prompt names every offer with the line the host wrote about it" do
      prompt = declare.to_prompt

      assert_includes prompt, "update_payment_method: Update payment method"
      assert_includes prompt, "offer this when the card on file is expiring"
      assert_includes prompt, Actions::PREFIX
    end

    test "the prompt never shows the agent an href" do
      # It has no use for one, and showing it invites the model to quote a URL
      # into its prose — which is a customer-facing link nobody declared.
      refute_includes declare.to_prompt, "/account#payment"
    end

    test "an empty vocabulary renders no section at all" do
      assert_nil Actions.new.to_prompt
    end

    # --- Extraction: the trailing line is metadata, never copy -----------------

    test "the actions line is pulled out and stripped from the reply" do
      selected = Actions.extract("Your card expires soon.\n\nActions-Offered: update_payment_method")

      assert_equal %w[update_payment_method], selected.keys
      assert_equal "Your card expires soon.", selected.text
    end

    test "several keys on one line, comma- or space-separated" do
      assert_equal %w[yes_please open_drafts],
                   Actions.extract("Hi.\nActions-Offered: yes_please, open_drafts").keys
    end

    test "no line is not a claim" do
      selected = Actions.extract("Your card expires soon.")

      assert_empty selected.keys
      assert_equal "Your card expires soon.", selected.text
    end

    test "an explicit none names nothing" do
      assert_empty Actions.extract("Nothing to do.\nActions-Offered: none").keys
    end

    test "prose on the line cannot conjure a button" do
      # A model that answers the instruction in English rather than in keys is
      # answering nothing: a key is matched whole, so "payment" is not
      # "update_payment_method".
      selected = Actions.extract("Hi.\nActions-Offered: I think they should update their payment method!")

      assert_empty declare.resolve(selected.keys)
    end

    private

    def declare
      Actions.new.tap do |actions|
        actions.offer :update_payment_method,
                      label:    "Update payment method",
                      use_when: "the card on file is expiring, missing, or has been declined",
                      href:     "/account#payment"
        actions.offer :yes_please,
                      label:    "Yes, help me with that.",
                      use_when: "the customer need only say yes",
                      reply:    "Yes, help me with that."
      end
    end
  end

  # The engine's half: advertise the vocabulary, carry back the selection, and
  # never let the machine-readable line reach a customer.
  class ActionsRunTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)

      Concierge.configure do |c|
        c.actions do
          offer :update_payment_method, label: "Update payment method",
                use_when: "the card on file is expiring", href: "/account#payment"
        end
      end
    end

    test "the vocabulary reaches the agent's prompt" do
      Concierge::Test::FakeChat.script(reply: "ok")

      Run.proactive(@subject, instruction: "Check in.")

      assert_includes Concierge::Test::FakeChat.current.system_prompt, "update_payment_method"
    end

    test "a named key comes back resolved into the host's own offer" do
      Concierge::Test::FakeChat.script(
        reply: "Your card expires in March.\n\nActions-Offered: update_payment_method"
      )

      result = Run.proactive(@subject, instruction: "Check in.")

      assert_equal [ "update_payment_method" ], result.actions_offered.map(&:key)
      assert_equal "Update payment method", result.actions_offered.sole.label
      assert_empty result.unknown_action_keys
    end

    test "the customer never sees the machine-readable line" do
      Concierge::Test::FakeChat.script(
        reply: "Your card expires in March.\n\nActions-Offered: update_payment_method"
      )

      result = Run.proactive(@subject, instruction: "Check in.")

      assert_equal "Your card expires in March.", result.reply_text
      refute_includes result.reply_text, Actions::PREFIX
    end

    test "the line is stripped even from an agent with no vocabulary at all" do
      # A model that emits the trailer unprompted must not leak it into an inbox
      # just because this host declared nothing to offer.
      Concierge.config.actions.clear
      Concierge::Test::FakeChat.script(reply: "All good.\n\nActions-Offered: something")

      result = Run.proactive(@subject, instruction: "Check in.")

      assert_equal "All good.", result.reply_text
      assert_empty result.actions_offered
    end

    test "an undeclared key offers nothing and is recorded as unknown" do
      Concierge::Test::FakeChat.script(reply: "Here.\n\nActions-Offered: cancel_their_account")

      result = Run.proactive(@subject, instruction: "Check in.")

      assert_empty result.actions_offered
      assert_equal %w[cancel_their_account], result.unknown_action_keys
    end

    test "rules citation and actions coexist on the same reply" do
      Concierge::Test::FakeChat.script(
        reply: "Your card expires in March.\n\nRules-Applied: none\nActions-Offered: update_payment_method"
      )

      result = Run.proactive(@subject, instruction: "Check in.")

      assert_equal "Your card expires in March.", result.reply_text
      assert_equal [ "update_payment_method" ], result.actions_offered.map(&:key)
    end

    # --- ...and out through the one delivery door -----------------------------

    test "the delivered payload carries the host's offers, not the model's words" do
      Concierge::Test::FakeChat.script(
        reply: "Your card expires in March.\n\nActions-Offered: update_payment_method"
      )
      result = Run.proactive(@subject, instruction: "Check in.")

      assert_equal :delivered, Outreach.deliver(result, @subject, channel: :in_app)

      payload = Concierge::InAppInbox.messages.sole
      assert_equal [ { key: "update_payment_method", label: "Update payment method",
                       href: "/account#payment" } ], payload[:actions]
    end

    test "a message with no offers carries no actions key" do
      Concierge::Test::FakeChat.script(reply: "All good.")
      result = Run.proactive(@subject, instruction: "Check in.")

      Outreach.deliver(result, @subject, channel: :in_app)

      assert_not Concierge::InAppInbox.messages.sole.key?(:actions)
    end
  end
end
