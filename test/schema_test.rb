require "test_helper"

module Concierge
  # The schema half of the keystone (design §10.1/§10.9). These assert against
  # the migrated database, so a table quietly dropped from — or wrongly added to —
  # the agent dimension fails here rather than in production.
  class SchemaTest < ActiveSupport::TestCase
    AGENT_KEYED = [
      Concierge::Memory, Concierge::Conversation, Concierge::Routine,
      Concierge::ChannelDelivery, Concierge::BudgetLedger, Concierge::Handoff,
      Concierge::OutboxItem
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
