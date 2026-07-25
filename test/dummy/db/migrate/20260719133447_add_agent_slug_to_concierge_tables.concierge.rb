# This migration comes from concierge (originally 20260101000011)
# The keystone of Phase 10 (design §10.1/§10.9): identity becomes two-dimensional.
# Every per-agent table gains a string +agent_slug+ so state is keyed by the
# (Agent × Subject) pair rather than by the Subject alone.
#
# Expand/contract, exactly as §10.9 sequences it, per table:
#   1. add a nullable agent_slug
#   2. backfill it to the default agent ("csm") — every existing row *is* the CSM
#   3. add the agent dimension to the scoped indexes
#   4. flip agent_slug to null: false
#
# +concierge_outreach_preferences+ is deliberately absent: "email me less" is the
# customer's preference about being contacted at all, not one agent's private
# setting, so it stays subject-keyed (§10.1, confirmed by the step-0 spike §A2).
class AddAgentSlugToConciergeTables < ActiveRecord::Migration[7.1]
  # The tables §10.1 lists, each with the scoped indexes that must gain the new
  # leading dimension.
  TABLES = %w[
    concierge_memories
    concierge_conversations
    concierge_routines
    concierge_channel_deliveries
    concierge_budget_ledgers
    concierge_handoffs
    concierge_outbox_items
  ].freeze

  # Rows that predate the agent dimension all belong to the one agent that
  # existed. Mirrors Concierge::Configuration::DEFAULT_AGENT_SLUG, spelled out
  # here so the migration does not depend on runtime config.
  DEFAULT_AGENT_SLUG = "csm".freeze

  def up
    TABLES.each do |table|
      add_column table, :agent_slug, :string
      execute "UPDATE #{table} SET agent_slug = #{quote(DEFAULT_AGENT_SLUG)} WHERE agent_slug IS NULL"
    end

    reindex
    TABLES.each { |table| change_column_null table, :agent_slug, false }
  end

  def down
    restore_indexes
    TABLES.each { |table| remove_column table, :agent_slug }
  end

  private

  def reindex
    remove_index :concierge_memories, name: "index_concierge_memories_on_subject_active_category"
    remove_index :concierge_memories, name: "index_concierge_memories_on_subject_recency"
    add_index :concierge_memories,
      [ :agent_slug, :subject_type, :subject_id, :active, :category ],
      name: "index_concierge_memories_on_scope_active_category"
    add_index :concierge_memories,
      [ :agent_slug, :subject_type, :subject_id, :updated_at ],
      name: "index_concierge_memories_on_scope_recency"

    # One persistent conversation per (agent, subject) — without the agent
    # dimension two agents over one subject share a Chat, and every prior turn of
    # the CSM's thread lands in the billing agent's context window.
    remove_index :concierge_conversations, name: "index_concierge_conversations_on_subject"
    add_index :concierge_conversations,
      [ :agent_slug, :subject_type, :subject_id ],
      unique: true, name: "index_concierge_conversations_on_scope"

    remove_index :concierge_routines, name: "index_concierge_routines_on_subject"
    add_index :concierge_routines,
      [ :agent_slug, :subject_type, :subject_id ],
      name: "index_concierge_routines_on_scope"

    remove_index :concierge_channel_deliveries, name: "index_concierge_deliveries_on_subject_and_sent_at"
    add_index :concierge_channel_deliveries,
      [ :agent_slug, :subject_type, :subject_id, :sent_at ],
      name: "index_concierge_deliveries_on_scope_and_sent_at"
    # Governance counts a subject's sends across every agent (one customer, one
    # inbox), so the subject-only lookup keeps its own index.
    add_index :concierge_channel_deliveries,
      [ :subject_type, :subject_id, :sent_at ],
      name: "index_concierge_deliveries_on_subject_and_sent_at"

    remove_index :concierge_budget_ledgers, name: "index_concierge_budget_ledgers_on_subject_window"
    add_index :concierge_budget_ledgers,
      [ :agent_slug, :subject_type, :subject_id, :window_on ],
      unique: true, name: "index_concierge_budget_ledgers_on_scope_window"

    remove_index :concierge_handoffs, name: "index_concierge_handoffs_on_subject_and_state"
    add_index :concierge_handoffs,
      [ :agent_slug, :subject_type, :subject_id, :state ],
      name: "index_concierge_handoffs_on_scope_and_state"

    remove_index :concierge_outbox_items, name: "index_concierge_outbox_on_subject_and_state"
    add_index :concierge_outbox_items,
      [ :agent_slug, :subject_type, :subject_id, :state ],
      name: "index_concierge_outbox_on_scope_and_state"
  end

  def restore_indexes
    remove_index :concierge_memories, name: "index_concierge_memories_on_scope_active_category"
    remove_index :concierge_memories, name: "index_concierge_memories_on_scope_recency"
    add_index :concierge_memories,
      [ :subject_type, :subject_id, :active, :category ],
      name: "index_concierge_memories_on_subject_active_category"
    add_index :concierge_memories,
      [ :subject_type, :subject_id, :updated_at ],
      name: "index_concierge_memories_on_subject_recency"

    remove_index :concierge_conversations, name: "index_concierge_conversations_on_scope"
    add_index :concierge_conversations,
      [ :subject_type, :subject_id ],
      unique: true, name: "index_concierge_conversations_on_subject"

    remove_index :concierge_routines, name: "index_concierge_routines_on_scope"
    add_index :concierge_routines,
      [ :subject_type, :subject_id ],
      name: "index_concierge_routines_on_subject"

    remove_index :concierge_channel_deliveries, name: "index_concierge_deliveries_on_scope_and_sent_at"

    remove_index :concierge_budget_ledgers, name: "index_concierge_budget_ledgers_on_scope_window"
    add_index :concierge_budget_ledgers,
      [ :subject_type, :subject_id, :window_on ],
      unique: true, name: "index_concierge_budget_ledgers_on_subject_window"

    remove_index :concierge_handoffs, name: "index_concierge_handoffs_on_scope_and_state"
    add_index :concierge_handoffs,
      [ :subject_type, :subject_id, :state ],
      name: "index_concierge_handoffs_on_subject_and_state"

    remove_index :concierge_outbox_items, name: "index_concierge_outbox_on_scope_and_state"
    add_index :concierge_outbox_items,
      [ :subject_type, :subject_id, :state ],
      name: "index_concierge_outbox_on_subject_and_state"
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
