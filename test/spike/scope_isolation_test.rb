require "test_helper"

module Concierge
  module Spike
    # THE load-bearing invariant of Phase 10 (design §10.12): the cross-account
    # isolation test becomes a cross-(agent, account) test. No query may escape
    # either dimension.
    #
    # The grid is 2 agents × 2 accounts = 4 private namespaces, plus the reserved
    # shared one. Every assertion below is "this cell sees itself and nothing
    # else it should not."
    class ScopeIsolationTest < ActiveSupport::TestCase
      setup do
        Concierge::Test.configure_agents!

        @acme  = subject_for(Tenant.create!(name: "Acme",  plan: "pro"))
        @globex = subject_for(Tenant.create!(name: "Globex", plan: "enterprise"))

        @grid = {
          [ :csm,     :acme ]   => Concierge::Spike::Scope.new(agent(:csm),     @acme),
          [ :csm,     :globex ] => Concierge::Spike::Scope.new(agent(:csm),     @globex),
          [ :billing, :acme ]   => Concierge::Spike::Scope.new(agent(:billing), @acme),
          [ :billing, :globex ] => Concierge::Spike::Scope.new(agent(:billing), @globex)
        }

        @store = Concierge::Spike::MemoryStore.new
        @grid.each do |(agent_slug, account), scope|
          @store.remember(scope, body: "private note for #{agent_slug}/#{account}")
        end
      end

      test "the Scope key we are committing to carries both dimensions" do
        scope = @grid[[ :billing, :acme ]]

        assert_equal({ agent_slug: "billing", subject_type: "account",
                       subject_id: @acme.id.to_s },
                     scope.target_key)
      end

      test "two Scopes are equal only when agent AND subject match" do
        assert_equal @grid[[ :csm, :acme ]], Concierge::Spike::Scope.new(agent(:csm), @acme)
        refute_equal @grid[[ :csm, :acme ]], @grid[[ :billing, :acme ]]
        refute_equal @grid[[ :csm, :acme ]], @grid[[ :csm, :globex ]]
        assert_equal 4, @grid.values.uniq.size
      end

      test "every cell of the (agent x account) grid sees exactly its own row" do
        @grid.each do |(agent_slug, account), scope|
          rows = Concierge::Memory.for_scope(scope)

          assert_equal 1, rows.count,
                       "#{agent_slug}/#{account} saw #{rows.count} rows"
          assert_equal "private note for #{agent_slug}/#{account}", rows.first.body
        end
      end

      test "no query escapes the agent dimension" do
        csm_bodies     = @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body)
        billing_bodies = @store.top_of_mind(@grid[[ :billing, :acme ]]).map(&:body)

        refute_includes csm_bodies,     "private note for billing/acme"
        refute_includes billing_bodies, "private note for csm/acme"
      end

      test "no query escapes the account dimension" do
        acme_bodies = @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body)

        refute_includes acme_bodies, "private note for csm/globex"
        assert_equal 0, Concierge::Memory.for_scope(@grid[[ :csm, :globex ]])
                                         .where("body LIKE '%acme%'").count
      end

      test "a soft-delete cannot reach across either dimension" do
        other = Concierge::Memory.for_scope(@grid[[ :billing, :acme ]]).first

        assert_nil @store.forget(@grid[[ :csm, :acme ]], other.id)
        assert other.reload.active, "a CSM forget retired a billing row"
      end

      test "the shared namespace is readable by every agent and owned by none" do
        @store.remember(@grid[[ :csm, :acme ]], body: "Acme is an EU entity", shared: true)

        assert_includes @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body),
                        "Acme is an EU entity"
        assert_includes @store.top_of_mind(@grid[[ :billing, :acme ]]).map(&:body),
                        "Acme is an EU entity"

        # ...but only for that account, and it is not in either agent's own space.
        refute_includes @store.top_of_mind(@grid[[ :csm, :globex ]]).map(&:body),
                        "Acme is an EU entity"
        refute_includes Concierge::Memory.for_scope(@grid[[ :csm, :acme ]]).map(&:body),
                        "Acme is an EU entity"
      end

      test "sharing is opt-in: an ordinary write stays private" do
        @store.remember(@grid[[ :billing, :acme ]], body: "card on file expires in March")

        refute_includes @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body),
                        "card on file expires in March"
      end

      test "a tool bound to a scope writes only inside that namespace" do
        scope = @grid[[ :billing, :acme ]]
        tool  = Concierge::Tools::RememberTool.new(
          subject: @acme, scope: scope, store: @store
        )

        tool.execute(body: "invoice #42 is disputed")

        assert_includes Concierge::Memory.for_scope(scope).map(&:body), "invoice #42 is disputed"
        refute_includes Concierge::Memory.for_scope(@grid[[ :csm, :acme ]]).map(&:body),
                        "invoice #42 is disputed"
        refute_includes Concierge::Memory.for_scope(@grid[[ :billing, :globex ]]).map(&:body),
                        "invoice #42 is disputed"
      end

      test "routines are per (agent, account) too" do
        csm     = @grid[[ :csm, :acme ]]
        billing = @grid[[ :billing, :acme ]]

        Concierge::Tools::RoutineTool.new(subject: @acme, scope: csm)
                                     .execute(action: "create", schedule: "0 9 * * 1",
                                              instruction: "weekly activation nudge")

        assert_equal 1, Concierge::Routine.for_scope(csm).count
        assert_equal 0, Concierge::Routine.for_scope(billing).count
        assert_equal 0, Concierge::Routine.for_scope(
          Concierge::Spike::Scope.new(agent(:csm), @globex)
        ).count
      end

      test "an un-scoped tool still keys by subject alone" do
        # The single-agent path is untouched: no scope bound, no namespace.
        Concierge::Tools::RememberTool.new(subject: @acme).execute(body: "legacy note")

        assert_includes Concierge::Memory.for_subject(@acme).map(&:body), "legacy note"
        @grid.each_value do |scope|
          refute_includes Concierge::Memory.for_scope(scope).map(&:body), "legacy note"
        end
      end

      private

      def agent(slug)
        Concierge.config.agent(slug)
      end

      def subject_for(tenant)
        tenant.users.create!(email: "user@#{tenant.name.downcase}.test")
        Concierge.config.account.build(tenant)
      end
    end
  end
end
