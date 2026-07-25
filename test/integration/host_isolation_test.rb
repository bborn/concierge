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
end
