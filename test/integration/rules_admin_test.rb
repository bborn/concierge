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

  # The screen an operator reads the audit trail on must not let a self-report
  # pass for evidence. A live model has cited a rule while contradicting it
  # (§10.4), and that run is indistinguishable here from a compliant one — so the
  # column has to say what it is at the point of reading.
  test "the runs screen presents a citation as the agent's own unverified claim" do
    rule = Concierge::Rules.propose(@scope, body: "Never mention automation.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    # Verbatim shape of the live turn that motivated this: the model does the
    # opposite of the rule and cites it on the way out.
    Concierge::Test::FakeChat.script(
      reply: "Yes — I'm an AI assistant helping out with support.\n\nRules-Applied: #{rule.id}"
    )
    Concierge::Run.reactive(@scope, "is this automated? am I talking to a bot?")

    get "/concierge/admin/runs"

    assert_response :success
    assert_includes response.body, "claims"
    assert_includes response.body, "claimed, not verified"
    assert_includes response.body, "not proof the rule was followed"
    # ...and it must not be labelled as something the agent simply did.
    refute_includes response.body, "<th>Rules cited</th>"
  end

  test "the runs screen names the injected pins as the evidence, distinct from the claim" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    Concierge::Test::FakeChat.script(reply: "I'll check.\n\nRules-Applied: #{rule.id}")
    Concierge::Run.reactive(@scope, "when does it ship?")

    get "/concierge/admin/runs"

    assert_includes response.body, "(engine — evidence)"
    assert_includes response.body, "written by the engine"
    # The remedy an operator should reach for when a rule has to actually bind.
    assert_includes response.body, "guard"
  end

  test "a run with no citation is not decorated with a compliance claim" do
    rule = Concierge::Rules.propose(@scope, body: "Never quote a delivery date.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    Concierge::Test::FakeChat.script(reply: "Hello!")
    Concierge::Run.reactive(@scope, "hi")

    get "/concierge/admin/runs"

    refute_includes response.body, "claimed, not verified"
  end

  # A claim an operator cannot check is not an audit trail. The index labels the
  # citation as unverified; this is the screen where the verifying actually
  # happens, because it is the only one that shows what the agent said.
  test "a run can be opened to read what the agent actually said" do
    Concierge.config.chat_factory = persisting_chat_factory
    rule = Concierge::Rules.propose(@scope, body: "Never mention automation.", author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")

    run = with_model_reply(
      "Yes — I'm an AI assistant helping out with support.\n\nRules-Applied: #{rule.id}"
    ) { Concierge::Run.reactive(@scope, "is this automated?") }.run_record

    get "/concierge/admin/runs"

    assert_response :success
    assert_select "a[href=?]", "/concierge/admin/runs/#{run.id}"

    get "/concierge/admin/runs/#{run.id}"

    assert_response :success
    # The claim, the evidence, and — the point of the screen — the words.
    assert_includes response.body, "Never mention automation."
    assert_includes response.body, "claimed, not verified"
    assert_includes response.body, "Yes — I&#39;m an AI assistant helping out with support."
    assert_includes response.body, "What the agent actually said"
  end

  # The reply is untrusted model output rendered on an operator's own screen. A
  # model that wrapped its answer in markup could otherwise put a link — or a
  # bolded reassurance — into the page the auditor is reading it on.
  test "a reply is escaped, never rendered as markup" do
    Concierge.config.chat_factory = persisting_chat_factory
    run = with_model_reply("<a href='https://evil.test'>everything is fine</a>") do
      Concierge::Run.reactive(@scope, "hi")
    end.run_record

    get "/concierge/admin/runs/#{run.id}"

    assert_includes response.body, "&lt;a href=&#39;https://evil.test&#39;&gt;"
    refute_includes response.body, "<a href='https://evil.test'>"
  end

  test "a run screen says plainly when there is no reply to check against" do
    Concierge::Test::FakeChat.script(reply: "Hello!")
    run = Concierge::Run.reactive(@scope, "hi").run_record

    get "/concierge/admin/runs/#{run.id}"

    assert_response :success
    assert_includes response.body, "no assistant message was"
    assert_includes response.body, "cannot be spot-checked"
    refute_includes response.body, "Hello!"
  end

  test "a pruned reply is reported as pruned, not as an empty one" do
    Concierge.config.chat_factory = persisting_chat_factory
    run = with_model_reply("Read me while you can.") { Concierge::Run.reactive(@scope, "hi") }.run_record
    run.reply_message.destroy!

    get "/concierge/admin/runs/#{run.id}"

    assert_response :success
    assert_includes response.body, "has pruned this message"
    assert_includes response.body, "cannot be spot-checked"
  end

  test "the run screen fails closed like every other admin screen" do
    Concierge::Test::FakeChat.script(reply: "Hello!")
    run = Concierge::Run.reactive(@scope, "hi").run_record
    Concierge.config.authenticate_admin = nil

    get "/concierge/admin/runs/#{run.id}"

    assert_response :forbidden
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
