require "test_helper"

module Concierge
  # Per-run provenance and the Playbook read path (design §10.2 read path, §10.4).
  #
  # The question this makes answerable: *which policy, at which version, was in
  # the prompt when the agent said what it said?*
  class RunProvenanceTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 2.days.ago)
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
      @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    end

    # --- the read path -------------------------------------------------------

    test "active rules are rendered into the prompt; proposed ones are not" do
      active   = activate(@csm, "Never quote a delivery date without checking the API.")
      proposed = Rules.propose(@csm, body: "Always open with an apology.", author: "a")

      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@csm, "when will it ship?")
      prompt = Concierge::Test::FakeChat.current.system_prompt

      assert_includes prompt, "Playbook"
      assert_includes prompt, active.body
      refute_includes prompt, proposed.body
      assert_includes prompt, "[rule #{active.id} v#{active.version}]"
    end

    test "one agent's rules never reach another agent's prompt" do
      csm_rule     = activate(@csm, "Never quote a delivery date.")
      billing_rule = activate(@billing, "Always attach the invoice PDF.")

      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@billing, "where is my invoice?")
      prompt = Concierge::Test::FakeChat.current.system_prompt

      assert_includes prompt, billing_rule.body
      refute_includes prompt, csm_rule.body
    end

    test "another account's rule never reaches this account's prompt" do
      other = Concierge.config.account.build(Tenant.create!(name: "Globex", plan: "enterprise"))
      other_scope = Concierge::Scope.new(Concierge.config.agent(:csm), other)
      theirs = activate(other_scope, "Globex pays by wire; never mention the card on file.")

      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@csm, "hi")

      refute_includes Concierge::Test::FakeChat.current.system_prompt, theirs.body
    end

    test "an agent-wide rule reaches every account that agent serves" do
      rule  = activate_wide(@csm, "Never promise a delivery date.")
      other = Concierge.config.account.build(Tenant.create!(name: "Globex", plan: "enterprise"))

      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(Concierge::Scope.new(Concierge.config.agent(:csm), other), "hi")

      assert_includes Concierge::Test::FakeChat.current.system_prompt, rule.body
    end

    test "no active rules means no Playbook section in the prompt" do
      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@csm, "hi")

      refute_includes Concierge::Test::FakeChat.current.system_prompt, "Playbook"
    end

    # --- the snapshot --------------------------------------------------------

    test "a run snapshots the exact rule ids and versions it was given" do
      rule = activate(@csm, "Never quote a delivery date.")
      Rules.edit!(rule, by: "sam@acme.test", body: "Never quote a delivery date without checking.")

      Concierge::Test::FakeChat.script(reply: "ok")
      result = Concierge::Run.reactive(@csm, "hi")

      run = result.run_record
      assert_equal [ { "id" => rule.id, "version" => 2 } ], run.rules
      assert_equal "csm", run.agent_slug
      assert_equal "reactive", run.trigger
      assert_equal "ok", run.status
    end

    test "the pinned version resolves to the text that was actually in the prompt" do
      rule = activate(@csm, "Never quote a delivery date.")
      Concierge::Test::FakeChat.script(reply: "ok")
      run = Concierge::Run.reactive(@csm, "hi").run_record

      # ...and then the rule is rewritten to say the opposite.
      Rules.edit!(rule, by: "sam@acme.test", body: "Always quote a delivery date.")

      assert_equal [ "[rule #{rule.id} v1] Never quote a delivery date." ],
                   run.reload.injected_rule_texts
      assert_equal "Always quote a delivery date.", rule.reload.body
    end

    test "a run records the memories, digest, model and tokens behind the decision" do
      memory = ContextStore.new.remember(@csm, body: "prefers Slack over email")
      Concierge::Test::FakeChat.script(reply: "ok", input_tokens: 120, output_tokens: 30)

      run = Concierge::Run.reactive(@csm, "hi").run_record

      assert_equal [ memory.id ], run.memory_ids
      assert_equal Snapshot.for(@subject, playbook: Concierge.config.agent(:csm).playbook).digest,
                   run.snapshot_digest
      assert_equal "claude-sonnet-4-5", run.model
      assert_equal 150, run.total_tokens
    end

    test "two agents over one account record two different snapshot digests" do
      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@csm, "hi")
      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@billing, "hi")

      digests = AgentRun.order(:id).pluck(:agent_slug, :snapshot_digest).to_h

      refute_equal digests["csm"], digests["billing"]
    end

    test "a failed run is still recorded, with the error class" do
      Concierge::Test::FakeChat.raise_with(RubyLLM::Error.new(nil, "boom"))

      Concierge::Run.reactive(@csm, "hi")

      run = AgentRun.sole
      assert_equal "failed", run.status
      assert_equal "RubyLLM::Error", run.error_class
    end

    test "a suppressed run records nothing — there was no prompt to snapshot" do
      Handoff.seize!(@csm, operator: "sam")

      result = Concierge::Run.proactive(@csm, instruction: "check in")

      assert result.suppressed?
      assert_equal 0, AgentRun.count
    end

    test "a broken provenance write never swallows the reply" do
      # Audit is a side channel: the run happened whether or not we recorded it.
      with_unwritable_provenance do
        Concierge::Test::FakeChat.script(reply: "Hi there!")
        result = Concierge::Run.reactive(@csm, "hi")

        assert result.ok?
        assert_equal "Hi there!", result.reply_text
        assert_nil result.run_record
      end
    end

    # --- citations -----------------------------------------------------------

    test "the agent's citation is captured and stripped from the reply" do
      rule = activate(@csm, "Never quote a delivery date.")
      Concierge::Test::FakeChat.script(
        reply: "I'll check with our ops team and come back to you.\n\nRules-Applied: #{rule.id}"
      )

      result = Concierge::Run.reactive(@csm, "when does it ship?")

      assert_equal [ rule.id ], result.rule_ids_applied
      assert_equal "I'll check with our ops team and come back to you.", result.reply_text
      refute_includes result.reply_text, "Rules-Applied"
      assert_equal [ rule.id ], result.run_record.rule_ids_applied
    end

    test "a citation for a rule that was never injected is flagged, not dropped" do
      rule = activate(@csm, "Never quote a delivery date.")
      Concierge::Test::FakeChat.script(reply: "Sure.\n\nRules-Applied: #{rule.id}, 9999")

      result = Concierge::Run.reactive(@csm, "hi")

      assert_equal [ rule.id, 9999 ], result.rule_ids_applied
      assert_equal [ 9999 ], result.unknown_rule_ids
      assert result.run_record.unknown_citations?
    end

    test "`Rules-Applied: none` is a claim of nothing, not a parse failure" do
      activate(@csm, "Never quote a delivery date.")
      Concierge::Test::FakeChat.script(reply: "Hello!\nRules-Applied: none")

      result = Concierge::Run.reactive(@csm, "hi")

      assert_empty result.rule_ids_applied
      assert_equal "Hello!", result.reply_text
    end

    # Characterization, not a regression guard: this documents a limit of the
    # design rather than asserting a fix. A live model was observed answering
    # "yes — I'm an AI assistant" to a rule saying never to mention automation,
    # and citing that rule (§10.4). The engine cannot detect that — it never sees
    # the rule's meaning, only its id coming back — so the row it writes is
    # identical to a genuinely compliant turn's. That is precisely why nothing
    # downstream may render a citation as compliance.
    test "a reply that contradicts the cited rule records as a clean citation" do
      rule = activate(@csm, "Keep the tone low-key and never mention automation.")
      Concierge::Test::FakeChat.script(
        reply: "Yes — I'm an AI assistant helping out with support.\n\nRules-Applied: #{rule.id}"
      )

      result = Concierge::Run.reactive(@csm, "is this automated? am I talking to a bot?")
      run    = result.run_record

      assert_equal [ rule.id ], run.rule_ids_applied
      assert_empty run.unknown_rule_ids
      refute run.unknown_citations?
      # ...and the pins — the half that *is* evidence — still say what it was told.
      assert_equal [ rule.id ], run.injected_rule_ids
      assert_includes run.injected_rule_texts.first, "never mention automation"
    end

    test "a reply with no citation line claims nothing and is left alone" do
      activate(@csm, "Never quote a delivery date.")
      Concierge::Test::FakeChat.script(reply: "Hello!")

      result = Concierge::Run.reactive(@csm, "hi")

      assert_empty result.rule_ids_applied
      assert_empty result.unknown_rule_ids
      assert_equal "Hello!", result.reply_text
    end

    test "the stripped reply is what gets delivered to the customer" do
      rule = activate(@csm, "Never quote a delivery date.")
      Concierge::Test::FakeChat.script(reply: "On its way!\n\nRules-Applied: #{rule.id}")

      result = Concierge::Run.proactive(@csm, instruction: "let them know it shipped")
      Outreach.deliver(result, @csm, channel: :in_app)

      assert_equal "On its way!", InAppInbox.messages.last[:body]
    end

    # --- retention -----------------------------------------------------------

    test "provenance rows can be pruned on the host's own cadence" do
      Concierge::Test::FakeChat.script(reply: "ok")
      Concierge::Run.reactive(@csm, "hi")
      AgentRun.sole.update_column(:created_at, 100.days.ago)

      AgentRun.prune!(older_than: 90.days)

      assert_equal 0, AgentRun.count
    end

    private

    # The audit table refusing writes, for real rather than through a mock: the
    # method is replaced and then removed, so the inherited create! comes back.
    def with_unwritable_provenance
      AgentRun.define_singleton_method(:create!) do |**|
        raise ActiveRecord::StatementInvalid, "audit table unavailable"
      end
      yield
    ensure
      AgentRun.singleton_class.send(:remove_method, :create!)
    end

    def activate(scope, body)
      rule = Rules.propose(scope, body: body, author: "drafter@acme.test")
      Rules.activate!(rule, by: "sam@acme.test")
      rule
    end

    def activate_wide(scope, body)
      rule = Rules.propose(scope, body: body, applies_to: :agent, author: "drafter@acme.test")
      Rules.activate!(rule, by: "sam@acme.test")
      rule
    end
  end
end
