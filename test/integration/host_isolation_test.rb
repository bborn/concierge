require "test_helper"

# The load-bearing invariant, asked of the *host surface* this time.
# test/scope_isolation_test.rb proves no query crosses an agent or an account
# boundary; this proves the product screens that sit on top of those queries did
# not quietly reintroduce a way across. Signing in as Dana at Acme must never
# surface Globex's anything.
class HostIsolationTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup do
    @globex.changelog_entries.create!(title: "Globex ships SSO", status: "published",
                                      published_at: 1.day.ago)
    deliver_in_app(csm_scope(@globex), "Globex: three entries published this quarter.")
    Concierge::ContextStore.new.remember(csm_scope(@globex),
                                         body: "Globex renewal is in November.")
    Concierge::Proposal.propose(billing_scope(@globex), action_class: "record.plan_change",
                                                        payload: { from: "enterprise", to: "pro" })
    Concierge::Handoff.seize!(csm_scope(@globex), operator: "someone@globex.test")

    sign_in_as @dana
  end

  test "no host page leaks another account's name, content or state" do
    [ root_path, changelog_entries_path, inbox_path, account_path ].each do |path|
      get path
      assert_response :success

      # The account switcher in the header deliberately lists every seat — that
      # is the demo. Everything below it is this account's, and only this
      # account's.
      body = css_select("main.page").to_s
      assert_no_match(/Globex/, body, "#{path} leaked another account")
      assert_no_match(/renewal is in November/, body, "#{path} leaked another account's memory")
      assert_no_match(/three entries published/, body, "#{path} leaked another account's outreach")
    end
  end

  test "the switcher is the only place another account is named, and it takes a POST" do
    get root_path

    assert_select "form[action=?] select option", signin_path, text: /Hank at Globex/
    assert_select ".whoami form[method=post]"
  end

  test "Globex's handoff does not make Acme's agent look stepped back" do
    get account_path

    assert_select ".pill--good", text: "on"
    assert_select "[data-kit-form]"
  end

  test "Globex's pending proposal is not Acme's pending request" do
    get account_path

    assert_select ".card__row", text: /Your request is with our team/, count: 0
    assert_select "form[action=?]", plan_change_path
  end

  test "a review for Acme writes only into Acme's namespace" do
    Concierge::Test::FakeChat.script(reply: "Acme, and only Acme.")

    post agent_review_path

    assert_equal 1, @acme.inbox_messages.count
    assert_equal 1, @globex.inbox_messages.count, "Globex keeps the one it already had"
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@globex)).count
  end

  test "chatting as Acme never reads Globex's memory into the prompt" do
    Concierge::ContextStore.new.remember(csm_scope(@acme), body: "Acme wants a Q3 launch.")
    Concierge::Test::FakeChat.script(reply: "Noted.")

    post "/concierge/accounts/#{@acme.id}/chat", params: { message: "hi", agent: "csm" }

    prompt = Concierge::Test::FakeChat.current.system_prompt
    assert_includes prompt, "Acme wants a Q3 launch."
    assert_not_includes prompt, "Globex renewal is in November."
  end

  # The host's own screens never render another account's subject_id — but the
  # engine's endpoints take it out of the URL, so "the host never shows it" is not
  # the same as "the engine will not answer it". Everything below is a request
  # nobody has to be tricked into making: a signed-in customer typing another
  # tenant's id into the URL a browser already has.
  test "the chat endpoint refuses another account's subject_id" do
    Concierge::Test::FakeChat.script(reply: "should never be assembled")

    post "/concierge/accounts/#{@globex.id}/chat", params: { message: "hi", agent: "csm" }

    assert_response :forbidden
    assert_nil response.parsed_body["reply"]
    assert_empty Concierge::Test::FakeChat.current.prompts,
                 "a refused request still ran a turn"
    assert_not_includes Concierge::Test::FakeChat.current.system_prompt,
                        "Globex renewal is in November.",
                        "a refused request still assembled Globex's state into a prompt"
    assert_equal 0, Concierge::AgentRun.for_scope(csm_scope(@globex)).count
    assert_equal 0, Concierge::Conversation.for_scope(csm_scope(@globex)).count
  end

  test "the chat endpoint refuses another account under every agent" do
    %w[csm billing].each do |slug|
      Concierge::Test::FakeChat.script(reply: "should never be assembled")

      post "/concierge/accounts/#{@globex.id}/chat", params: { message: "hi", agent: slug }

      assert_response :forbidden, "the #{slug} agent answered for another account"
    end
  end

  test "a signed-out request is refused too" do
    delete signout_path
    Concierge::Test::FakeChat.script(reply: "should never be assembled")

    post "/concierge/accounts/#{@acme.id}/chat", params: { message: "hi", agent: "csm" }

    assert_response :forbidden
  end

  test "the operator handoff endpoints refuse another account's subject_id" do
    post "/concierge/accounts/#{@globex.id}/handoff", params: { operator: "dana@acme.test" }
    assert_response :forbidden

    post "/concierge/accounts/#{@globex.id}/handoff/message", params: { body: "Dana here." }
    assert_response :forbidden

    # Globex's own handoff (seized in setup by someone at Globex) is untouched:
    # neither seized by Dana, nor released by her, nor written into.
    handoff = Concierge::Handoff.active_for(csm_scope(@globex))
    assert_equal "someone@globex.test", handoff.operator
    assert_equal 0, Concierge::Memory.for_scope(csm_scope(@globex))
                                     .where(body: "Dana here.").count
  end

  test "releasing another account's thread is refused" do
    delete "/concierge/accounts/#{@globex.id}/handoff"

    assert_response :forbidden
    assert Concierge::Handoff.active_for(csm_scope(@globex)),
           "Dana released Globex's handoff and put their agent back on the thread"
  end

  test "an account that does not exist is refused the same way one that is not yours is" do
    # Otherwise the refusal is an existence oracle: 403 for real accounts, 404
    # for made-up ones, and the id space is enumerable from outside.
    post "/concierge/accounts/#{Tenant.maximum(:id) + 1}/chat", params: { message: "hi" }
    not_yours = response.status

    post "/concierge/accounts/#{@globex.id}/chat", params: { message: "hi" }

    assert_equal response.status, not_yours
    assert_response :forbidden
  end

  test "Dana keeps every endpoint she is entitled to" do
    # The gate has to refuse the neighbour without costing the customer their own
    # agent — a fix that shut the endpoint for everyone would pass every test
    # above and break the product.
    Concierge::Test::FakeChat.script(reply: "Happy to help!")
    post "/concierge/accounts/#{@acme.id}/chat", params: { message: "hi", agent: "csm" }
    assert_response :success
    assert_equal "Happy to help!", response.parsed_body["reply"]

    post "/concierge/accounts/#{@acme.id}/handoff", params: { operator: "support@acme.test" }
    assert_response :created
    assert Concierge::Handoff.active_for(csm_scope(@acme))
  end
end
