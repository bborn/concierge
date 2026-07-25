require "test_helper"

module Concierge
  # A rule that graduated from advice to invariant (design §10.2): the predicate
  # is checked by the engine, so the policy holds whether or not the model felt
  # like following it.
  class RulesGuardTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @scope   = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    end

    test "an advisory rule is never enforced by the engine" do
      guard_rule("Never mention a refund.", predicate: nil, enforcement: "advisory")

      assert_empty Rules.guard_violations(@scope, action_class: Authority::MESSAGE_OUTREACH,
                                                  payload: { body: "here is your refund" })
    end

    test "a guard rule with no conditions denies its whole action class" do
      rule = guard_rule("This agent never sends outbound mail.",
                        predicate: { "action_class" => Authority::MESSAGE_OUTREACH })

      violations = Rules.guard_violations(@scope, action_class: Authority::MESSAGE_OUTREACH,
                                                  payload: { body: "hello" })

      assert_equal [ rule.id ], violations.map(&:id)
    end

    test "a guard rule scoped to another action class does not fire" do
      guard_rule("Never issue a refund over $50.",
                 predicate: { "action_class" => "money.refund",
                              "deny_when" => { "amount_cents" => { "gt" => 5000 } } })

      assert_empty Rules.guard_violations(@scope, action_class: Authority::MESSAGE_OUTREACH,
                                                  payload: { amount_cents: 9000 })
    end

    test "every condition must hold for the action to be denied" do
      guard_rule("Never refund over $50 without a reason.",
                 predicate: { "action_class" => "money.refund",
                              "deny_when" => { "amount_cents" => { "gt" => 5000 },
                                               "reason" => { "absent" => true } } })

      denied = Rules.guard_violations(@scope, action_class: "money.refund",
                                              payload: { amount_cents: 9000 })
      allowed = Rules.guard_violations(@scope, action_class: "money.refund",
                                               payload: { amount_cents: 9000, reason: "damaged" })
      under = Rules.guard_violations(@scope, action_class: "money.refund",
                                             payload: { amount_cents: 100 })

      assert_equal 1, denied.size
      assert_empty allowed
      assert_empty under
    end

    test "a guard predicate reads nested payload keys by dot path" do
      guard_rule("Never touch an order that has already shipped.",
                 predicate: { "deny_when" => { "order.state" => "shipped" } })

      assert_equal 1, Rules.guard_violations(@scope, action_class: "record.update",
                                                     payload: { order: { state: "shipped" } }).size
      assert_empty Rules.guard_violations(@scope, action_class: "record.update",
                                                  payload: { order: { state: "packing" } })
    end

    test "matches, in, and present operators" do
      assert Rules::Guard.new({ "deny_when" => { "body" => { "matches" => "guarantee" } } })
                         .violates?(action_class: "x", payload: { body: "We GUARANTEE it" })
      assert Rules::Guard.new({ "deny_when" => { "channel" => { "in" => %w[email sms] } } })
                         .violates?(action_class: "x", payload: { channel: "sms" })
      refute Rules::Guard.new({ "deny_when" => { "channel" => { "in" => %w[email sms] } } })
                         .violates?(action_class: "x", payload: { channel: "in_app" })
      assert Rules::Guard.new({ "deny_when" => { "token" => { "present" => true } } })
                         .violates?(action_class: "x", payload: { token: "abc" })
    end

    test "a typo'd operator raises rather than silently stopping guarding" do
      guard = Rules::Guard.new({ "deny_when" => { "amount" => { "greater_than" => 5 } } })

      assert_raises(Concierge::Error) { guard.violates?(action_class: "x", payload: { amount: 9 }) }
    end

    test "a guard rule short-circuits an outbound send" do
      guard_rule("Never put the word guarantee in a customer email.",
                 predicate: { "action_class" => Authority::MESSAGE_OUTREACH,
                              "deny_when" => { "body" => { "matches" => "guarantee" } } })

      blocked = Outreach.deliver(Result.new(reply_text: "We guarantee delivery Friday."), @scope,
                                 channel: :in_app)
      allowed = Outreach.deliver(Result.new(reply_text: "It should arrive Friday."), @scope,
                                 channel: :in_app)

      assert_equal :blocked_by_rule, blocked
      # :billing gates on authority, so a permitted send still stages for a human —
      # the point is that the guard refused *before* the envelope was consulted.
      assert_equal :drafted, allowed
      assert_equal 1, OutboxItem.for_scope(@scope).count
    end

    test "a guard rule in one agent's scope never binds another agent" do
      guard_rule("Never put the word guarantee in a customer email.",
                 predicate: { "action_class" => Authority::MESSAGE_OUTREACH,
                              "deny_when" => { "body" => { "matches" => "guarantee" } } })

      csm = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)

      assert_equal :delivered,
                   Outreach.deliver(Result.new(reply_text: "We guarantee delivery Friday."), csm,
                                    channel: :in_app)
    end

    private

    def guard_rule(body, predicate:, enforcement: "guard", scope: @scope)
      rule = Rules.propose(scope, body: body, author: "a",
                           predicate: predicate, enforcement: enforcement)
      Rules.activate!(rule, by: "sam@acme.test")
      rule
    end
  end
end
