require "test_helper"

module Concierge
  module Spike
    # Spike acceptance (design §10.10): a proactive run for each agent does not
    # cross-contaminate prompt or memory, and provenance records the right
    # agent_slug.
    class MultiAgentRunTest < ActiveSupport::TestCase
      setup do
        Concierge::Test.configure_agents!

        tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
        tenant.users.create!(email: "dana@acme.test")
        @subject = Concierge.config.account.build(tenant)

        @csm     = Concierge::Spike.scope_for(:csm, @subject)
        @billing = Concierge::Spike.scope_for(:billing, @subject)

        store = Concierge::Spike::MemoryStore.new
        store.remember(@csm,     body: "champion is Dana; CEO is skeptical of AI")
        store.remember(@billing, body: "card on file expires in March")
        store.remember(@csm,     body: "Acme is an EU entity", shared: true)
      end

      test "each agent's proactive prompt carries its own persona, brief and memory" do
        csm_prompt     = prompt_from { Concierge::Spike::Run.proactive(@csm, instruction: "weekly check-in") }
        billing_prompt = prompt_from { Concierge::Spike::Run.proactive(@billing, instruction: "invoice review") }

        assert_includes csm_prompt, "Kit"
        assert_includes csm_prompt, "Acme helps teams publish changelogs."
        assert_includes csm_prompt, "champion is Dana"
        assert_includes csm_prompt, "has_paid_plan: yes"      # the CSM's signals

        assert_includes billing_prompt, "Bill"
        assert_includes billing_prompt, "Acme bills monthly per seat."
        assert_includes billing_prompt, "card on file expires in March"
        assert_includes billing_prompt, "seat_count: 1"       # billing's own signals
      end

      test "neither prompt leaks the other agent's persona, brief, or memory" do
        csm_prompt     = prompt_from { Concierge::Spike::Run.proactive(@csm, instruction: "weekly check-in") }
        billing_prompt = prompt_from { Concierge::Spike::Run.proactive(@billing, instruction: "invoice review") }

        refute_includes csm_prompt, "Bill"
        refute_includes csm_prompt, "card on file expires in March"
        refute_includes csm_prompt, "Acme bills monthly per seat."
        refute_includes csm_prompt, "seat_count"

        refute_includes billing_prompt, "Kit"
        refute_includes billing_prompt, "champion is Dana"
        refute_includes billing_prompt, "Acme helps teams publish changelogs."
        refute_includes billing_prompt, "has_paid_plan"
      end

      test "both prompts carry the shared namespace" do
        csm_prompt     = prompt_from { Concierge::Spike::Run.proactive(@csm, instruction: "a") }
        billing_prompt = prompt_from { Concierge::Spike::Run.proactive(@billing, instruction: "b") }

        assert_includes csm_prompt,     "Acme is an EU entity"
        assert_includes billing_prompt, "Acme is an EU entity"
      end

      test "each agent gets only its own tools" do
        csm_tools     = tools_from { Concierge::Spike::Run.proactive(@csm, instruction: "a") }
        billing_tools = tools_from { Concierge::Spike::Run.proactive(@billing, instruction: "b") }

        assert_includes csm_tools, "manage_routine"
        assert_includes csm_tools, "set_outreach_preference"
        assert_equal %w[recall remember], billing_tools.sort
      end

      test "a tool call during a run writes into that agent's namespace only" do
        Concierge::Test::FakeChat.script(
          reply: "Noted.",
          tool_calls: [ { name: "remember", arguments: { body: "invoice #42 is disputed" } } ]
        )
        Concierge::Spike::Run.proactive(@billing, instruction: "invoice review")

        assert_includes Concierge::Memory.for_scope(@billing).map(&:body), "invoice #42 is disputed"
        refute_includes Concierge::Memory.for_scope(@csm).map(&:body), "invoice #42 is disputed"
      end

      test "provenance records the agent that ran, with what it was given" do
        Concierge::Test::FakeChat.script(reply: "ok", input_tokens: 300, output_tokens: 40)
        Concierge::Spike::Run.proactive(@csm, instruction: "weekly check-in")

        Concierge::Test::FakeChat.script(reply: "ok", input_tokens: 120, output_tokens: 20)
        Concierge::Spike::Run.proactive(@billing, instruction: "invoice review")

        rows = Concierge::Spike::Provenance.recent
        assert_equal %w[billing csm], rows.map(&:agent_slug).sort

        csm_row     = Concierge::Spike::Provenance.for_agent(:csm).first
        billing_row = Concierge::Spike::Provenance.for_agent(:billing).first

        assert_equal "account", csm_row.subject_type
        assert_equal @subject.id.to_s, csm_row.subject_id
        assert_equal "proactive", csm_row.trigger
        assert_equal 340, csm_row.total_tokens
        assert_equal 140, billing_row.total_tokens

        # The memory ids each run actually injected — disjoint but for the shared row.
        csm_private     = Concierge::Memory.for_scope(@csm).pluck(:id)
        billing_private = Concierge::Memory.for_scope(@billing).pluck(:id)
        assert (csm_row.memory_ids & billing_private).empty?,
               "the CSM's provenance names a billing memory"
        assert (billing_row.memory_ids & csm_private).empty?,
               "billing's provenance names a CSM memory"

        # Different playbooks mean different engagement signals mean different
        # snapshots — the digest proves the two runs saw different state.
        refute_equal csm_row.snapshot_digest, billing_row.snapshot_digest
      end

      test "the two agents hold two separate persistent conversations" do
        Concierge::Test::FakeChat.script(reply: "a")
        Concierge::Spike::Run.proactive(@csm, instruction: "a")
        Concierge::Test::FakeChat.script(reply: "b")
        Concierge::Spike::Run.proactive(@billing, instruction: "b")

        csm_chat     = Concierge::Conversation.find_by_scope(@csm).chat_id
        billing_chat = Concierge::Conversation.find_by_scope(@billing).chat_id

        refute_equal csm_chat, billing_chat
      end

      test "a takeover on one agent's thread does not silence the other" do
        Concierge::Handoff.create!(**@csm.key, operator: "bruno@acme.test",
                                   state: "active", seized_at: Time.current)

        Concierge::Test::FakeChat.script(reply: "should not send")
        suppressed = Concierge::Spike::Run.proactive(@csm, instruction: "weekly check-in")
        assert suppressed.suppressed?

        Concierge::Test::FakeChat.script(reply: "billing carries on")
        assert Concierge::Spike::Run.proactive(@billing, instruction: "invoice review").ok?
      end

      test "a provider error still comes back as a failed Result, never raised" do
        Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))

        result = nil
        assert_nothing_raised { result = Concierge::Spike::Run.proactive(@csm, instruction: "a") }
        refute result.ok?
        assert_empty Concierge::Spike::Provenance.recent
      end

      private

      def prompt_from
        Concierge::Test::FakeChat.script(reply: "ok")
        yield
        Concierge::Test::FakeChat.current.system_prompt
      end

      def tools_from
        Concierge::Test::FakeChat.script(reply: "ok")
        yield
        Concierge::Test::FakeChat.current.tools.map { |t| t.name.to_s }
      end
    end
  end
end
