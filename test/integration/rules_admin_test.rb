require "test_helper"

# The human gate as a screen (design §10.2). The properties that matter here are
# the refusals: this is the surface an operator meets, so a blocked activation has
# to arrive as something actionable rather than a 500 — or as a silent success.
class RulesAdminTest < ActionDispatch::IntegrationTest
  setup do
    Concierge::Test.configure_agents!
    Concierge.config.authenticate_admin = ->(_c) { true }
    Concierge.config.admin_actor        = ->(_c) { "sam@acme.test" }

    @tenant = Tenant.create!(name: "Acme", plan: "pro")
    @tenant.users.create!(email: "dana@acme.test")
    @subject = Concierge.config.account.build(@tenant)
    @scope   = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
  end

  test "the rules screen fails closed like every other admin screen" do
    Concierge.config.authenticate_admin = nil
    get "/concierge/admin/rules"
    assert_response :forbidden
  end

  test "a proposal card shows the instruction, its provenance and who drafted it" do
    Concierge::Rules.propose(
      @scope,
      body:       "Never quote a delivery date without checking the shipping API.",
      author:     Concierge::Rules.agent_actor(:csm),
      provenance: { "source" => "human_correction",
                    "verbatim" => "You told them Friday again. Never quote a date.",
                    "corrected_by" => "dana@acme.test" }
    )

    get "/concierge/admin/rules"

    assert_response :success
    assert_includes response.body, "Never quote a delivery date without checking the shipping API."
    assert_includes response.body, "You told them Friday again."
    assert_includes response.body, "agent:csm"
    assert_includes response.body, "Approve — make active"
  end

  test "an operator approves a proposal and it goes into force" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")

    patch "/concierge/admin/rules/#{rule.id}", params: { transition: "activate" }

    assert_redirected_to "/concierge/admin/rules"
    assert rule.reload.active?
    assert_equal "sam@acme.test", rule.approver
  end

  test "without an admin_actor hook the gate refuses rather than inventing an approver" do
    Concierge.config.admin_actor = nil
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")

    patch "/concierge/admin/rules/#{rule.id}", params: { transition: "activate" }

    assert_redirected_to "/concierge/admin/rules"
    assert rule.reload.proposed?
    follow_redirect!
    assert_includes response.body, "without a human approver"
  end

  test "the cap refusal arrives as an actionable message, not a 500" do
    Concierge.config.active_rule_cap = 1
    first = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(first, by: "sam@acme.test")
    extra = Concierge::Rules.propose(@scope, body: "Greet them by first name.", author: "agent:csm")

    patch "/concierge/admin/rules/#{extra.id}", params: { transition: "activate" }

    assert_redirected_to "/concierge/admin/rules"
    assert extra.reload.proposed?
    follow_redirect!
    assert_includes response.body, "Consolidate or retire one of these first"
    assert_includes response.body, "Never quote a delivery date."
  end

  test "an unresolved conflict blocks the tap, and can be acknowledged from the screen" do
    existing = Concierge::Rules.propose(@scope, body: "Always attach the invoice PDF.", author: "agent:csm")
    Concierge::Rules.activate!(existing, by: "sam@acme.test")
    candidate = Concierge::Rules.propose(@scope, body: "Never attach the invoice PDF.", author: "agent:csm")

    patch "/concierge/admin/rules/#{candidate.id}", params: { transition: "activate" }
    assert candidate.reload.proposed?
    follow_redirect!
    assert_includes response.body, "conflicts with"

    patch "/concierge/admin/rules/#{candidate.id}",
          params: { transition: "activate", acknowledge_conflicts: "1" }
    assert candidate.reload.active?
  end

  test "an UNCHECKED acknowledge box does not wave the conflict through" do
    # Found by driving the real screen: Rails' check_box posts its hidden partner
    # value "0" when unchecked, and "0".present? is true. Checking presence instead
    # of casting let every conflict through from a browser while the gate still
    # looked correct from a console. This is the browser's exact payload.
    existing = Concierge::Rules.propose(@scope, body: "Always attach the invoice PDF.", author: "agent:csm")
    Concierge::Rules.activate!(existing, by: "sam@acme.test")
    candidate = Concierge::Rules.propose(@scope, body: "Never attach the invoice PDF.", author: "agent:csm")

    patch "/concierge/admin/rules/#{candidate.id}",
          params: { transition: "activate", acknowledge_conflicts: "0" }

    assert candidate.reload.proposed?, "an unchecked box acknowledged the conflict"
    follow_redirect!
    assert_includes response.body, "conflicts with"
  end

  test "an operator rejects a proposal, and it does not read as retired" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")

    patch "/concierge/admin/rules/#{rule.id}", params: { transition: "reject" }

    assert_equal "rejected", rule.reload.state
  end

  test "an operator retires an active rule" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")

    patch "/concierge/admin/rules/#{rule.id}", params: { transition: "deprecate" }

    assert rule.reload.deprecated?
  end

  test "an unknown transition changes nothing" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")

    patch "/concierge/admin/rules/#{rule.id}", params: { transition: "obliterate" }

    assert rule.reload.proposed?
  end

  test "a retirement proposal shows its evidence next to the rule" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    Concierge::Rules.propose_retirement!(
      rule, evidence: { "reason" => "never cited", "runs_injected" => 9 }
    )

    get "/concierge/admin/rules"

    assert_includes response.body, "never cited"
    assert_includes response.body, "in 9 prompts, never cited"
  end

  test "the run provenance screen shows the exact rule text a decision was given" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    Concierge::Test::FakeChat.script(reply: "I'll check.\n\nRules-Applied: #{rule.id}")
    Concierge::Run.reactive(@scope, "when does it ship?")

    # ...and then the rule is rewritten to say the opposite.
    Concierge::Rules.edit!(rule, by: "sam@acme.test", body: "Always quote a delivery date.")

    get "/concierge/admin/runs"

    assert_response :success
    assert_includes response.body, "[rule #{rule.id} v1] Never quote a delivery date."
    refute_includes response.body, "Always quote a delivery date."
  end

  test "the runs screen flags a citation for a rule that was never injected" do
    Concierge::Test::FakeChat.script(reply: "Sure.\n\nRules-Applied: 4242")
    Concierge::Run.reactive(@scope, "hi")

    get "/concierge/admin/runs"

    assert_includes response.body, "cited but never injected: 4242"
  end

  test "the agents screen links the rules in force to the screen that gates them" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    Concierge::Rules.propose(@scope, body: "Greet them by first name.", author: "agent:csm")

    get "/concierge/admin/agents"

    assert_includes response.body, "1 active rule"
    assert_includes response.body, "1 awaiting a human tap"
    assert_includes response.body, "/concierge/admin/rules"
  end
end
