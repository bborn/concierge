require "test_helper"

module Concierge
  # The plural config DSL and its six slots (design §10.1), plus the §10.9
  # back-compat rule: a host that never calls +config.agent+ *is* the CSM.
  class AgentTest < ActiveSupport::TestCase
    test "an un-pluralized host is the implicit :csm agent" do
      agent = Concierge.config.agent

      assert_equal :csm, agent.slug
      assert_equal [ :csm ], Concierge.config.agents.map(&:slug)
      refute Concierge.config.agent_declared?(:csm)

      # The very same objects the top-level blocks returned — not copies that
      # could drift from the host's configuration.
      assert_same Concierge.config.playbook,     agent.playbook
      assert_same Concierge.config.capabilities, agent.capabilities
      assert_equal "Kit", agent.persona.name
    end

    test "reading an agent nobody declared returns nil" do
      assert_nil Concierge.config.agent(:billing)
      refute Concierge.config.agent_declared?(:billing)
    end

    test "draft_and_review set AFTER the agent was first read still folds in" do
      # The staleness the step-0 spike flagged (§D5): the implicit agent reads its
      # slots through to the Configuration, so late configuration is never lost.
      assert_equal :autonomous,
                   Concierge.config.agent.authority.level_for(Authority::MESSAGE_OUTREACH)

      Concierge.config.draft_and_review = true

      assert_equal :human_approval,
                   Concierge.config.agent.authority.level_for(Authority::MESSAGE_OUTREACH)
    end

    test "top-level capabilities registered after the first read still reach the agent" do
      agent = Concierge.config.agent
      before = agent.capabilities.entries.size

      Concierge.configure { |c| c.capabilities { register Concierge::Tools::ForgetTool, access: :write } }

      assert_equal before + 1, agent.capabilities.entries.size
    end

    test "two agents coexist with distinct personas, models, tools and authority" do
      Concierge::Test.configure_agents!

      csm     = Concierge.config.agent(:csm)
      billing = Concierge.config.agent(:billing)

      assert_equal %i[csm billing], Concierge.config.agents.map(&:slug)

      assert_equal "Kit",  csm.persona.name
      assert_equal "Bill", billing.persona.name
      refute_equal csm.playbook.product_brief, billing.playbook.product_brief

      assert_equal 5, csm.capabilities.entries.size
      assert_equal 2, billing.capabilities.entries.size
      refute_includes billing.capabilities.entries.map(&:tool_class),
                      Concierge::Tools::RoutineTool

      assert_equal :autonomous,      csm.authority.level_for(Authority::MESSAGE_OUTREACH)
      assert_equal :human_approval,  billing.authority.level_for(Authority::MESSAGE_OUTREACH)
      assert_equal :human_execution, billing.authority.level_for("money.refund")
      assert billing.authority.human_execution?("money.refund")
      refute billing.authority.autonomous?("money.refund")
    end

    test "an agent block called twice extends the same agent" do
      Concierge.configure { |c| c.agent(:ops) { persona name: "Ops" } }
      Concierge.configure { |c| c.agent(:ops) { model "claude-haiku-4-5-20251001" } }

      agent = Concierge.config.agent(:ops)
      assert_equal "Ops", agent.persona.name
      assert_equal "claude-haiku-4-5-20251001", agent.model
      assert_equal 1, Concierge.config.agents.size
    end

    test "an agent runs on the global default model unless it names its own" do
      Concierge::Test.configure_agents!
      Concierge.configure { |c| c.agent(:billing) { model "claude-haiku-4-5-20251001" } }

      Concierge::Test::FakeChat.script(reply: "ok")
      csm = Concierge::Run.proactive(scope_for(:csm), instruction: "check")
      assert_equal "claude-sonnet-4-5", csm.model

      Concierge::Test::FakeChat.script(reply: "ok")
      billing = Concierge::Run.proactive(scope_for(:billing), instruction: "check")
      assert_equal "claude-haiku-4-5-20251001", billing.model
    end

    test "an unknown authority level is refused at configure time" do
      error = assert_raises(Concierge::Error) do
        Concierge.configure { |c| c.agent(:ops) { authority { default :yolo } } }
      end
      assert_match(/unknown authority level/, error.message)
    end

    test "the memory namespace is the slug and is not separately configurable" do
      Concierge::Test.configure_agents!

      assert_equal "billing", Concierge.config.agent(:billing).memory_namespace
      refute Concierge.config.agent(:billing).respond_to?(:memory_namespace=)
    end

    test "the kill switch stops that agent and only that agent" do
      Concierge::Test.configure_agents!
      Concierge.configure { |c| c.agent(:billing) { enabled false } }

      Concierge::Test::FakeChat.script(reply: "ok")
      halted = Concierge::Run.proactive(scope_for(:billing), instruction: "check")
      assert halted.suppressed?
      assert_match(/disabled/, halted.reply_text)

      Concierge::Test::FakeChat.script(reply: "still here")
      assert Concierge::Run.proactive(scope_for(:csm), instruction: "check").ok?
    end

    test "a disabled agent is stopped on the reactive path too" do
      Concierge::Test.configure_agents!
      Concierge.configure { |c| c.agent(:billing) { enabled false } }

      Concierge::Test::FakeChat.script(reply: "ok")
      assert Concierge::Run.reactive(scope_for(:billing), "hello").suppressed?
    end

    private

    def scope_for(slug)
      Concierge::Scope.new(Concierge.config.agent(slug), subject)
    end

    def subject
      @subject ||= begin
        tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
        tenant.users.create!(email: "dana@acme.test")
        Concierge.config.account.build(tenant)
      end
    end
  end
end
