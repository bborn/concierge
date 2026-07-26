require "test_helper"

module Concierge
  # The schema half of the keystone (design §10.1/§10.9). These assert against
  # the migrated database, so a table quietly dropped from — or wrongly added to —
  # the agent dimension fails here rather than in production.
  class SchemaTest < ActiveSupport::TestCase
    AGENT_KEYED = [
      Concierge::Memory, Concierge::Conversation, Concierge::Routine,
      Concierge::ChannelDelivery, Concierge::BudgetLedger, Concierge::Handoff,
      Concierge::AgentProposal, Concierge::AgentRule, Concierge::AgentRun
    ].freeze

    test "every per-agent table carries a non-null agent_slug" do
      AGENT_KEYED.each do |model|
        column = model.columns_hash["agent_slug"]

        assert column, "#{model.table_name} never gained agent_slug"
        assert_equal :string, column.type
        refute column.null, "#{model.table_name}.agent_slug should be NOT NULL"
      end
    end

    test "every per-agent table is agent-scoped, and outreach preferences is not" do
      AGENT_KEYED.each do |model|
        assert model.singleton_class.include?(AgentScoped::ClassMethods),
               "#{model} is not AgentScoped"
      end

      refute Concierge::OutreachPreference.column_names.include?("agent_slug")
      refute Concierge::OutreachPreference.singleton_class.include?(AgentScoped::ClassMethods)
    end

    test "a namespace blanked on purpose is refused; an absent one defaults" do
      blanked = Concierge::Memory.new(subject_type: "account", subject_id: "1",
                                      body: "x", agent_slug: "")
      refute blanked.valid?
      assert_includes blanked.errors.attribute_names, :agent_slug

      absent = Concierge::Memory.new(subject_type: "account", subject_id: "1", body: "x")
      assert absent.valid?
      assert_equal "csm", absent.agent_slug
    end

    test "one conversation per (agent, subject), not per subject" do
      index = Concierge::Conversation.connection
                                     .indexes("concierge_conversations")
                                     .find(&:unique)

      assert_equal %w[agent_slug subject_type subject_id], index.columns
    end

    test "the uniqueness validation moved with the index" do
      Concierge::Test.configure_agents!
      tenant  = Tenant.create!(name: "Acme", plan: "pro")
      subject = Concierge.config.account.build(tenant)
      csm     = Concierge::Scope.new(Concierge.config.agent(:csm), subject)
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), subject)

      Concierge::Conversation.create!(**csm.key, grain: "account", chat_id: 1)

      # A second agent over the same subject is fine...
      assert Concierge::Conversation.new(**billing.key, grain: "account", chat_id: 2).valid?
      # ...a second conversation for the same agent is not.
      refute Concierge::Conversation.new(**csm.key, grain: "account", chat_id: 3).valid?
    end

    test "a proposal's idempotency key is unique within its pair, not table-wide" do
      # Exactly-once execution (§10.6) is enforced on the row — Execute claims it
      # with a conditional UPDATE — so a table-wide unique index buys nothing and
      # costs the invariant: it makes one cell's key collide with another's.
      index = Concierge::AgentProposal.connection
                                      .indexes("concierge_agent_proposals")
                                      .find { |i| i.columns.include?("idempotency_key") }

      assert index, "the idempotency key lost its unique index"
      assert index.unique
      assert_equal %w[agent_slug subject_type subject_id idempotency_key], index.columns
    end

    test "the proposal uniqueness validation moved with that index too" do
      Concierge::Test.configure_agents!
      subject = Concierge.config.account.build(Tenant.create!(name: "Acme", plan: "pro"))
      csm     = Concierge::Scope.new(Concierge.config.agent(:csm), subject)
      billing = Concierge::Scope.new(Concierge.config.agent(:billing), subject)
      row     = { action_class: "record.update", gate: "human_approval", idempotency_key: "order-9" }

      Concierge::AgentProposal.create!(**csm.key, **row)

      assert Concierge::AgentProposal.new(**billing.key, **row).valid?,
             "another agent's proposal was refused for reusing a key"
      refute Concierge::AgentProposal.new(**csm.key, **row).valid?
    end

    test "only agent_rules may leave the subject half of the key blank" do
      # A rule can be agent-wide or segment-wide (§10.2), so its subject keys are
      # nullable — and it is the *only* table where that is true. Everything else
      # keyed by the pair must carry both halves.
      (AGENT_KEYED - [ Concierge::AgentRule ]).each do |model|
        refute model.columns_hash["subject_id"].null,
               "#{model.table_name}.subject_id should be NOT NULL"
      end

      assert Concierge::AgentRule.columns_hash["subject_id"].null
      assert Concierge::AgentRule.columns_hash["subject_type"].null
    end

    test "a rule with half a subject key is refused" do
      # Half a key would read as agent-wide on one query and subject-specific on
      # another, which is how an isolation hole gets in.
      half = Concierge::AgentRule.new(agent_slug: "csm", subject_type: "account", body: "x")

      refute half.valid?
      assert_includes half.errors.attribute_names, :subject_id
    end

    test "the rule revision trail is not agent-scoped, because it has no scope" do
      # A revision belongs to exactly one rule, which carries the keys. A second
      # copy of them would be a second source of truth that could drift.
      refute Concierge::AgentRuleRevision.column_names.include?("agent_slug")
      refute Concierge::AgentRuleRevision.singleton_class.include?(AgentScoped::ClassMethods)
    end

    test "rows that predate the agent dimension read as the default agent" do
      # What the migration's backfill guarantees, asserted through the same door
      # every query uses: a row with no namespace of its own is the CSM's.
      tenant  = Tenant.create!(name: "Acme", plan: "pro")
      subject = Concierge.config.account.build(tenant)
      row     = Concierge::Memory.create!(**subject.key, body: "written before Phase 10")

      assert_equal "csm", row.agent_slug
      assert_includes Concierge::Memory.for_subject(subject).map(&:body), "written before Phase 10"
    end
  end
end
