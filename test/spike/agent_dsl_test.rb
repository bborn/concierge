require "test_helper"

module Concierge
  module Spike
    # Does the plural DSL read well, and does declaring agent #2 leave agent #1
    # alone? (Spike acceptance, design §10.10.)
    class AgentDslTest < ActiveSupport::TestCase
      test "the plural DSL is inert until a host opts in" do
        refute Concierge::Spike.enabled?
        refute Concierge.config.agent_declared?(:csm)
        refute Concierge.config.agent_declared?(:billing)
        assert_nil Concierge.config.agent(:billing)
      end

      test "an un-pluralized host is the implicit :csm agent" do
        agent = Concierge.config.agent(:csm)

        assert_equal :csm, agent.slug
        # The very same objects the top-level blocks returned — not copies that
        # could drift from the host's configuration.
        assert_same Concierge.config.playbook,     agent.playbook
        assert_same Concierge.config.capabilities, agent.capabilities
        assert_equal "Kit", agent.persona.name
      end

      test "draft_and_review folds into the CSM's authority envelope" do
        Concierge.config.draft_and_review = true

        assert_equal :human_approval,
                     Concierge.config.agent(:csm).authority.level_for("message.outreach")
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

        assert_equal :autonomous,      csm.authority.level_for("message.outreach")
        assert_equal :human_approval,  billing.authority.level_for("message.outreach")
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

      test "an agent falls back to the global default model" do
        Concierge::Test.configure_agents!

        assert_nil Concierge.config.agent(:billing).model
        scope = Concierge::Spike.scope_for(:billing, subject)
        Concierge::Test::FakeChat.script(reply: "ok")

        result = Concierge::Spike::Run.proactive(scope, instruction: "check")
        assert_equal "claude-sonnet-4-5", result.model
      end

      test "an unknown authority level is refused at configure time" do
        error = assert_raises(Concierge::Error) do
          Concierge.configure { |c| c.agent(:ops) { authority { default :yolo } } }
        end
        assert_match(/unknown authority level/, error.message)
      end

      test "the kill switch stops that agent and only that agent" do
        Concierge::Test.configure_agents!
        Concierge.configure { |c| c.agent(:billing) { enabled false } }

        Concierge::Test::FakeChat.script(reply: "ok")
        halted = Concierge::Spike::Run.proactive(
          Concierge::Spike.scope_for(:billing, subject), instruction: "check"
        )
        assert halted.suppressed?
        assert_match(/disabled/, halted.reply_text)

        Concierge::Test::FakeChat.script(reply: "still here")
        alive = Concierge::Spike::Run.proactive(
          Concierge::Spike.scope_for(:csm, subject), instruction: "check"
        )
        assert alive.ok?

        # A halted agent is also dropped from the set a sweep would iterate.
        assert_equal [ :csm ], Concierge::Spike.scopes_for(subject).map { |s| s.agent.slug }
      end

      private

      def subject
        @subject ||= begin
          tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
          tenant.users.create!(email: "dana@acme.test")
          Concierge.config.account.build(tenant)
        end
      end
    end
  end
end
