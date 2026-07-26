require "test_helper"

# The *staff* half of the host-authorization seam (config.authorize_operator,
# Concierge::ScopedEndpoint). The customer half is
# test/integration/subject_authorization_test.rb.
#
# The engine's handoff endpoints seize a customer's thread, speak on it as the
# company, and land what is said as pinned human-sourced memory in that agent's
# namespace. Until this change they shared the chat endpoint's hook, so the
# question they asked was "is this account yours" — which a customer answers yes
# about their own account. Everything below is that distinction: two questions,
# two hooks, and neither standing in for the other in either direction.
class OperatorAuthorizationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
    @tenant.users.create!(email: "a@acme.test")
    @subject = Concierge.config.account.build(@tenant)
  end

  # --- Fails closed, and does not inherit an answer ---------------------------

  test "the operator endpoints are refused when only the customer hook is set" do
    # The regression. A host that writes the obvious tenant-match hook — the one
    # in the README and in this dummy app — has answered "is this account yours"
    # and nothing else. That must not be read as "and you are staff".
    Concierge::Test.authorize_all_subjects!

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "not-really-support" }
    assert_response :forbidden

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Support here." }
    assert_response :forbidden

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :forbidden

    assert_equal 0, Concierge::Handoff.count
    assert_equal 0, Concierge::Memory.count,
                 "a refused operator message still wrote human-sourced memory"
  end

  test "the refusal says which hook is missing, and that it is not the other one" do
    Concierge::Test.authorize_all_subjects!
    log = StringIO.new
    Concierge.config.logger = Logger.new(log)

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }

    assert_response :forbidden
    assert_includes log.string, "ERROR"
    assert_includes log.string, "config.authorize_operator"
    assert_includes log.string, "are you staff"
    assert_includes log.string, "separate hook"
  end

  test "the customer hook does not open the operator endpoints even when it inspects the request" do
    # A host *could* have written the staff clause inside authorize_subject —
    # that was the old advice. It no longer matters what it says: the operator
    # endpoints do not ask it at all, so a permissive one cannot leak into them.
    asked = []
    Concierge.configure do |c|
      c.authorize_subject = ->(controller, _scope) { asked << controller.request.path; true }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }

    assert_response :forbidden
    assert_empty asked, "the operator endpoint consulted the customer hook"
  end

  # --- ...and not in the other direction either -------------------------------

  test "the operator hook does not open the chat endpoint" do
    Concierge::Test.authorize_all_operators!
    Concierge::Test::FakeChat.script(reply: "should never be reached")

    post "/concierge/accounts/#{@tenant.id}/chat", params: { message: "hi" }

    assert_response :forbidden
    assert_equal "not authorized for this account", response.parsed_body["error"]
    assert_empty Concierge::Test::FakeChat.current.prompts
  end

  # --- What the operator hook is handed ---------------------------------------

  test "the hook is handed the controller and the resolved (agent, account) scope" do
    Concierge::Test.configure_agents!
    Concierge::Test.name_all_operators!
    seen = nil
    Concierge.configure do |c|
      c.authorize_operator = ->(controller, scope) { seen = [ controller, scope ]; true }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "billing" }

    assert_response :created
    controller, scope = seen
    assert_kind_of Concierge::HandoffsController, controller
    assert_respond_to controller, :session
    assert_equal "billing", scope.agent_slug
    assert_equal @tenant.id.to_s, scope.subject.id.to_s
  end

  test "an operator can be staff for one business function and not another" do
    # "Only the billing team may take the billing thread" is a real staffing
    # policy, which is why this hook is handed the Scope and not the subject.
    Concierge::Test.configure_agents!
    Concierge::Test.name_all_operators!
    Concierge.configure do |c|
      c.authorize_operator = ->(_controller, scope) { scope.agent_slug == "billing" }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "billing" }
    assert_response :created

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam", agent: "csm" }
    assert_response :forbidden

    assert_nil Concierge::Handoff.active_for(
      Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    )
  end

  test "a hook that says yes lets the whole takeover through" do
    Concierge::Test.authorize_all_operators!
    Concierge::Test.name_all_operators!

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }
    assert_response :created
    assert Concierge::Handoff.active_for(@subject)

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Hi, this is Sam." }
    assert_response :ok
    assert_equal "human", Concierge::Memory.for_subject(@subject).first.source

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :no_content
    assert_nil Concierge::Handoff.active_for(@subject)
    assert_equal "sam@acme.test", Concierge::Handoff.sole.released_by,
                 "the handback recorded when but not who"
  end

  test "an account that does not exist is refused the same way an unstaffed one is" do
    Concierge::Test.authorize_all_operators!
    Concierge::Test.name_all_operators!

    delete "/concierge/accounts/#{Tenant.maximum(:id) + 1}/handoff"

    assert_response :forbidden
  end

  # --- ...and a third question: who -------------------------------------------
  #
  # Passing the gate says the caller may act. It does not say who they are, and
  # until config.operator_actor existed the request answered that itself — so a
  # staff member who was allowed through could seize a thread under a colleague's
  # name, or the CEO's, and the customer would be told exactly that.

  test "the operator of record is the host's answer, not the request's" do
    Concierge::Test.authorize_all_operators!
    Concierge::Test.name_all_operators!("sam@acme.test")

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "ceo@acme.test" }

    assert_response :created
    assert_equal "sam@acme.test", Concierge::Handoff.active_for(@subject).operator,
                 "the caller named the operator of record"
  end

  test "who handed the thread back is the host's answer too, and need not be who took it" do
    # The half of the takeover that was recorded only as a timestamp. Releasing is
    # what re-enables this pair's autonomous proactive sends, so the name on it
    # matters for the same reason the seizing name does — and it comes off the
    # session the gate vouched for, not off the request.
    Concierge::Test.authorize_all_operators!
    Concierge::Test.name_all_operators!("sam@acme.test")
    post "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :created

    Concierge::Test.name_all_operators!("bill@acme.test")
    delete "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "ceo@acme.test" }

    assert_response :no_content
    handoff = Concierge::Handoff.sole
    assert_equal "sam@acme.test",  handoff.operator
    assert_equal "bill@acme.test", handoff.released_by,
                 "the caller named who handed the account back to an autonomous agent"
  end

  test "the identity hook is handed the controller and the resolved scope" do
    Concierge::Test.configure_agents!
    Concierge::Test.authorize_all_operators!
    seen = nil
    Concierge.configure do |c|
      c.operator_actor = ->(controller, scope) { seen = [ controller, scope ]; "bill@acme.test" }
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { agent: "billing" }

    assert_response :created
    controller, scope = seen
    assert_kind_of Concierge::HandoffsController, controller
    assert_respond_to controller, :session
    assert_equal "billing", scope.agent_slug
    assert_equal @tenant.id.to_s, scope.subject.id.to_s
  end

  test "an authorized operator the host will not name is refused, and nothing is recorded" do
    # The gate says yes and the identity hook is missing. Recording the takeover
    # anyway would show the customer a nameless human, and taking the name from
    # the request is the hole this closes — so it refuses.
    Concierge::Test.authorize_all_operators!

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "ceo@acme.test" }
    assert_response :forbidden

    post "/concierge/accounts/#{@tenant.id}/handoff/message", params: { body: "Support here." }
    assert_response :forbidden

    delete "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :forbidden

    assert_equal 0, Concierge::Handoff.count
    assert_equal 0, Concierge::Memory.count
  end

  test "a hook that answers with nothing has not named anybody" do
    # An empty string is not an operator, and neither is a lookup that missed.
    Concierge::Test.authorize_all_operators!

    [ nil, "", "   " ].each do |answer|
      Concierge.configure { |c| c.operator_actor = ->(_controller, _scope) { answer } }

      post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "ceo@acme.test" }

      assert_response :forbidden, "#{answer.inspect} was accepted as an operator"
    end

    assert_equal 0, Concierge::Handoff.count
  end

  test "the refusal says which hook is missing, and that it is not the authorization one" do
    Concierge::Test.authorize_all_operators!
    log = StringIO.new
    Concierge.config.logger = Logger.new(log)

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "sam" }

    assert_response :forbidden
    assert_includes log.string, "ERROR"
    assert_includes log.string, "config.operator_actor"
    assert_includes log.string, "who they are"
  end

  test "the refusal is indistinguishable from an unauthorized one" do
    # Otherwise the status code is an oracle: "you passed the staff gate but we
    # could not name you" tells an outsider they passed the staff gate.
    Concierge::Test.authorize_all_operators!
    post "/concierge/accounts/#{@tenant.id}/handoff"
    unnamed = response.status

    Concierge.reset_config!
    Concierge::Test.configure!
    post "/concierge/accounts/#{@tenant.id}/handoff"

    assert_equal response.status, unnamed
    assert_response :forbidden
  end

  test "the named operator authors the correction the takeover captures" do
    # A rule drafted from what an operator said has to carry who said it, the way
    # the Slack intake's does — otherwise the provenance trail stops at "a human".
    Concierge::Test.authorize_all_operators!
    Concierge::Test.name_all_operators!("sam@acme.test")

    post "/concierge/accounts/#{@tenant.id}/handoff"
    assert_response :created

    perform_enqueued_jobs do
      post "/concierge/accounts/#{@tenant.id}/handoff/message",
           params: { body: "Never quote a delivery date without checking with support." }
    end
    assert_response :ok

    rule = Concierge::AgentRule.sole
    assert_equal "sam@acme.test", rule.provenance["corrected_by"],
                 "the correction's author was not the operator who made it"
  end

  # --- The engine no longer reads params[:operator] ---------------------------

  test "a host whose console drives several operators can still let the request name them" do
    # The decision moves to the host, which is the point: it can require the
    # console to be entitled to before believing the parameter.
    Concierge::Test.authorize_all_operators!
    roster = %w[sam@acme.test bill@acme.test]
    Concierge.configure do |c|
      c.operator_actor = lambda do |controller, _scope|
        controller.params[:operator] if roster.include?(controller.params[:operator])
      end
    end

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "bill@acme.test" }
    assert_response :created
    assert_equal "bill@acme.test", Concierge::Handoff.active_for(@subject).operator

    Concierge::Handoff.active_for(@subject).release!(by: "bill@acme.test")

    post "/concierge/accounts/#{@tenant.id}/handoff", params: { operator: "ceo@acme.test" }
    assert_response :forbidden
  end
end
