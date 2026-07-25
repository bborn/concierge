require "test_helper"

module Concierge
  # Two agents over one account: a run for each must not cross-contaminate the
  # prompt, the memory, the tool set, or the persistent conversation (design
  # §10.1/§10.3, and the contamination vector the step-0 spike surfaced in §D1).
  class MultiAgentRunTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!

      tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
      tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(tenant)

      @csm     = scope_for(:csm)
      @billing = scope_for(:billing)

      store = Concierge::ContextStore.new
      store.remember(@csm,     body: "champion is Dana; CEO is skeptical of AI")
      store.remember(@billing, body: "card on file expires in March")
      store.remember(@csm,     body: "Acme is an EU entity", shared: true)
    end

    test "each agent's prompt carries its own persona, brief, signals and memory" do
      csm_prompt     = prompt_from { Concierge::Run.proactive(@csm, instruction: "weekly check-in") }
      billing_prompt = prompt_from { Concierge::Run.proactive(@billing, instruction: "invoice review") }

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
      csm_prompt     = prompt_from { Concierge::Run.proactive(@csm, instruction: "weekly check-in") }
      billing_prompt = prompt_from { Concierge::Run.proactive(@billing, instruction: "invoice review") }

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
      csm_prompt     = prompt_from { Concierge::Run.proactive(@csm, instruction: "a") }
      billing_prompt = prompt_from { Concierge::Run.proactive(@billing, instruction: "b") }

      assert_includes csm_prompt,     "Acme is an EU entity"
      assert_includes billing_prompt, "Acme is an EU entity"
    end

    test "an off-scope tool does not exist in that agent's loop" do
      csm_tools     = tools_from { Concierge::Run.proactive(@csm, instruction: "a") }
      billing_tools = tools_from { Concierge::Run.proactive(@billing, instruction: "b") }

      assert_includes csm_tools, "manage_routine"
      assert_includes csm_tools, "set_outreach_preference"
      # Not "registered but erroring" — simply absent from what the model can see.
      assert_equal %w[recall remember], billing_tools.sort
    end

    test "every tool a run hands the model is bound to that run's scope" do
      # Binding is what stops a tool call mid-run from writing outside its
      # agent's namespace, so assert it on the objects themselves rather than
      # only through one tool's side effect.
      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.proactive(@billing, instruction: "invoice review")

      tools = Concierge::Test::FakeChat.current.tools
      assert tools.any?
      assert tools.all? { |t| t.scope == @billing },
             "a tool was handed the model without its agent's scope"
    end

    test "a tool call during a run writes into that agent's namespace only" do
      Concierge::Test::FakeChat.script(
        reply: "Noted.",
        tool_calls: [ { name: "remember", arguments: { body: "invoice #42 is disputed" } } ]
      )
      Concierge::Run.proactive(@billing, instruction: "invoice review")

      assert_includes Concierge::Memory.for_scope(@billing).map(&:body), "invoice #42 is disputed"
      refute_includes Concierge::Memory.for_scope(@csm).map(&:body), "invoice #42 is disputed"
    end

    test "the two agents hold two separate persistent conversations" do
      Concierge::Test::FakeChat.script(reply: "a")
      Concierge::Run.proactive(@csm, instruction: "a")
      Concierge::Test::FakeChat.script(reply: "b")
      Concierge::Run.proactive(@billing, instruction: "b")

      csm_chat     = Concierge::Conversation.find_by_scope(@csm).chat_id
      billing_chat = Concierge::Conversation.find_by_scope(@billing).chat_id

      assert_equal 2, Concierge::Conversation.count
      refute_equal csm_chat, billing_chat
    end

    test "a takeover on one agent's thread does not silence the other" do
      Concierge::Handoff.seize!(@csm, operator: "bruno@acme.test")

      Concierge::Test::FakeChat.script(reply: "should not send")
      assert Concierge::Run.proactive(@csm, instruction: "weekly check-in").suppressed?

      Concierge::Test::FakeChat.script(reply: "billing carries on")
      assert Concierge::Run.proactive(@billing, instruction: "invoice review").ok?
    end

    test "the change gate is per agent: each sees its own snapshot digest" do
      # Different playbooks mean different engagement signals mean different
      # digests over the same account — so one agent's review never marks the
      # other's as done.
      assert Concierge::ChangeDetector.changed?(@csm)
      Concierge::ChangeDetector.mark_reviewed!(@csm)

      refute Concierge::ChangeDetector.changed?(@csm)
      assert Concierge::ChangeDetector.changed?(@billing), "billing inherited the CSM's review"

      Concierge::ChangeDetector.mark_reviewed!(@billing)
      refute_equal Concierge::Conversation.find_by_scope(@csm).last_snapshot_digest,
                   Concierge::Conversation.find_by_scope(@billing).last_snapshot_digest
    end

    test "the authority envelope decides whether an agent may send at all" do
      # :csm is autonomous-within-caps; :billing declares default :human_approval.
      # Billing goes first: a drafted proposal records no delivery, so the
      # cross-agent frequency cap is not what is being measured here.
      billing_status = Concierge::Outreach.deliver(
        Concierge::Result.new(reply_text: "an invoice question"), @billing, channel: :in_app
      )
      csm_status = Concierge::Outreach.deliver(
        Concierge::Result.new(reply_text: "a nudge"), @csm, channel: :in_app
      )

      assert_equal :delivered, csm_status
      assert_equal :drafted,   billing_status

      assert_equal 1, Concierge::AgentProposal.for_scope(@billing).proposed.count
      assert_equal 0, Concierge::AgentProposal.for_scope(@csm).proposed.count
      assert_equal "csm", Concierge::ChannelDelivery.sole.agent_slug
    end

    test "spend is attributed per agent but the tenant cap is read across them" do
      # One tenant's daily cap is the tenant's; per-agent caps would let N agents
      # each spend it. Attribution is per agent so an operator can see who burned it.
      Concierge.config.budget = { per_tenant: 100, global: 10_000 }
      budget = Concierge::Budget.new

      budget.spend!(@csm, 60)
      refute budget.exhausted?(@billing)

      budget.spend!(@billing, 50)
      assert budget.exhausted?(@csm), "the tenant cap did not bind across agents"

      assert_equal 60, budget.spent_for_scope(@csm)
      assert_equal 50, budget.spent_for_scope(@billing)
      assert_equal 110, budget.spent_for(@subject)
    end

    test "the frequency cap counts a customer's sends across every agent" do
      # One customer, one inbox. Content namespaces are per agent; the governance
      # rails are per customer.
      Concierge::Governance.new.record!(@csm, channel: "email", kind: "outreach")

      refute Concierge::Governance.new.allow?(@billing, kind: "outreach"),
             "billing sent inside the CSM's frequency window"
    end

    test "a provider error still comes back as a failed Result, never raised" do
      Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))

      result = nil
      assert_nothing_raised { result = Concierge::Run.proactive(@csm, instruction: "a") }
      refute result.ok?
    end

    private

    def scope_for(slug)
      Concierge::Scope.new(Concierge.config.agent(slug), @subject)
    end

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
