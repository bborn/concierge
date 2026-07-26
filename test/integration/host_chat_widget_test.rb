require "test_helper"

# The chat widget, and the path that could not be tested before it existed:
# POST /concierge/accounts/:subject_id/chat *with forgery protection on*, driven
# by the CSRF token a host page rendered. Every previous test of that endpoint
# ran with `allow_forgery_protection = false`, so it proved the controller and
# nothing about the pairing a browser actually has to make.
class HostChatWidgetTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  test "every page carries the widget, pointed at the engine's chat endpoint" do
    sign_in_as @dana

    [ root_path, changelog_entries_path, inbox_path, account_path ].each do |path|
      get path
      assert_select ".kit[data-chat-url=?]", "/concierge/accounts/#{@acme.id}/chat"
    end
  end

  test "the agent is shown by persona name, never as Concierge" do
    sign_in_as @dana
    get account_path

    assert_select ".kit__name", text: "Kit"
    assert_select ".kit", text: /Concierge/, count: 0
  end

  test "the widget's POST is accepted when it carries the token the page rendered" do
    sign_in_as @dana

    with_forgery_protection do
      get account_path
      token = csrf_token_from_page

      Concierge::Test::FakeChat.script(reply: "Happy to help!")

      post "/concierge/accounts/#{@acme.id}/chat",
           params:  { message: "how do I publish?", agent: "csm" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json", "X-CSRF-Token" => token }

      assert_response :success
      assert_equal "Happy to help!", response.parsed_body["reply"]
      assert_equal "csm", response.parsed_body["agent"]
    end
  end

  test "the same POST without the token is refused" do
    sign_in_as @dana

    with_forgery_protection do
      get account_path

      Concierge::Test::FakeChat.script(reply: "should never be reached")

      post "/concierge/accounts/#{@acme.id}/chat",
           params:  { message: "how do I publish?" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      assert_response :unprocessable_entity
    end
  end

  # The thing a real key would exercise for real: playbook + snapshot + memory +
  # the rules in force, assembled fresh, with a provenance row written for the
  # turn. Asserted on the prompt the widget's own POST produced, so "the model
  # sees the right thing" is not taken on trust.
  test "the widget's turn is given the playbook, this account's state, its memory and its rules" do
    sign_in_as @dana

    Concierge::ContextStore.new.remember(csm_scope(@acme), body: "Dana wants to ship before Q3.")
    rule = Concierge::Rules.propose(csm_scope(@acme), body: "Never promise a delivery date.",
                                                      author: "dana@acme.test")
    Concierge::Rules.activate!(rule, by: "operator@acme.test")

    Concierge::Test::FakeChat.script(reply: "Let's publish something.")
    post "/concierge/accounts/#{@acme.id}/chat", params: { message: "hi", agent: "csm" }
    assert_response :success

    prompt = Concierge::Test::FakeChat.current.system_prompt
    assert_includes prompt, "You are Kit, the csm agent for this account."
    assert_includes prompt, "Acme helps teams publish changelogs."
    assert_includes prompt, "published_changelogs: 0"
    assert_includes prompt, "Dana wants to ship before Q3."
    assert_includes prompt, "Never promise a delivery date."

    run = Concierge::AgentRun.for_scope(csm_scope(@acme)).sole
    assert_equal "reactive", run.trigger
    assert_equal [ rule.id ], run.injected_rule_ids
    assert_equal 1, run.memory_ids.size
  end

  test "the tools the turn is given are the CSM's, and only the CSM's" do
    sign_in_as @dana
    Concierge::Test::FakeChat.script(reply: "ok")

    post "/concierge/accounts/#{@acme.id}/chat", params: { message: "hi", agent: "csm" }
    csm_tools = Concierge::Test::FakeChat.current.tools.map { |t| t.class.name }

    Concierge::Test::FakeChat.script(reply: "ok")
    post "/concierge/accounts/#{@acme.id}/chat", params: { message: "hi", agent: "billing" }
    billing_tools = Concierge::Test::FakeChat.current.tools.map { |t| t.class.name }

    assert_includes csm_tools, "Concierge::Tools::RoutineTool"
    assert_not_includes billing_tools, "Concierge::Tools::RoutineTool"
  end

  test "the activity endpoint reports the tool calls of the last turn" do
    sign_in_as @dana

    # A real model's tool calls land on the messages *before* the final reply,
    # persisted by acts_as_chat. Offline there are none, so the rows are written
    # here — this is what the widget reads back to draw its ⚙ chips.
    chat      = Concierge::ChatResolver.call(csm_scope(@acme))
    Message.create!(chat_id: chat.id, role: "user", content: "remember this")
    assistant = Message.create!(chat_id: chat.id, role: "assistant", content: "")
    ToolCall.create!(message_id: assistant.id, tool_call_id: "call_1", name: "remember",
                     arguments: { body: "Dana wants a Q3 launch" })

    get agent_activity_path(agent: :csm)

    assert_response :success
    assert_equal [ "remember" ], response.parsed_body["tool_calls"].map { |c| c["name"] }
  end

  test "the activity endpoint only ever reads the signed-in account's conversation" do
    sign_in_as @dana

    chat      = Concierge::ChatResolver.call(csm_scope(@globex))
    assistant = Message.create!(chat_id: chat.id, role: "assistant", content: "")
    ToolCall.create!(message_id: assistant.id, tool_call_id: "call_2", name: "recall",
                     arguments: {})

    get agent_activity_path(agent: :csm)

    assert_response :success
    assert_empty response.parsed_body["tool_calls"]
  end

  # The demo, keyless, through the endpoint a browser actually posts to.
  #
  # ConciergeSetup installs its scripted stand-in only when ANTHROPIC_API_KEY is
  # unset, and test_helper always sets one — so every other test in this file runs
  # the host's config with FakeChat in place of it. That is deliberate (no test
  # may reach a model) but it means the offline wiring the demo actually ships is
  # exercised nowhere. Here it is, on purpose: no key, the host's own factory, and
  # the assertion the whole of task 5017 is about — a keyless turn is written down
  # where every transcript surface in the product reads from.
  test "a keyless host's widget turn lands in this account's conversation" do
    with_keyless_host do
      sign_in_as @dana

      post "/concierge/accounts/#{@acme.id}/chat",
           params: { message: "how do I publish?", agent: "csm" }

      assert_response :success
      assert_includes response.parsed_body["reply"], "Changelog"
    end

    scope = csm_scope(@acme)
    chat  = Concierge::Conversation.find_by_scope(scope)&.chat_record

    assert chat, "a keyless widget turn opened no conversation"
    assert_equal %w[user assistant], chat.messages.order(:id).map { |m| m.role.to_s }
    assert_equal "how do I publish?", chat.messages.order(:id).first.content

    run = Concierge::AgentRun.for_scope(scope).sole
    assert_equal chat.id, run.chat_id
    assert_nil run.prompt_unavailable_reason
    assert_nil run.reply_unavailable_reason
  end

  test "the widget hides the composer while a human holds the thread" do
    sign_in_as @dana
    Concierge::Handoff.seize!(csm_scope(@acme), operator: "support@acme.test")

    get account_path

    assert_select "[data-kit-form]", count: 0
    assert_select ".kit__notice", text: /stepped back/
  end
end
