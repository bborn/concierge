# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_26_090007) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "changelog_entries", force: :cascade do |t|
    t.integer "author_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "published_at"
    t.string "status", default: "draft", null: false
    t.integer "tenant_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_changelog_entries_on_author_id"
    t.index ["tenant_id", "status"], name: "index_changelog_entries_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_changelog_entries_on_tenant_id"
  end

  create_table "chats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "model_id"
    t.datetime "updated_at", null: false
    t.index ["model_id"], name: "index_chats_on_model_id"
  end

  create_table "concierge_agent_proposals", force: :cascade do |t|
    t.string "action_class", null: false
    t.bigint "agent_run_id"
    t.string "agent_slug", null: false
    t.datetime "approved_at"
    t.string "approved_by"
    t.datetime "corrected_at"
    t.string "corrected_by"
    t.datetime "created_at", null: false
    t.string "created_by"
    t.datetime "executed_at"
    t.string "executed_by"
    t.text "execution_error"
    t.datetime "execution_failed_at"
    t.datetime "execution_queued_at"
    t.datetime "expires_at"
    t.string "gate", null: false
    t.string "idempotency_key"
    t.text "original_payload"
    t.text "payload"
    t.string "precondition_digest"
    t.datetime "proposed_at"
    t.datetime "rejected_at"
    t.string "rejected_by"
    t.text "rejected_reason"
    t.text "rule_ids_applied"
    t.string "state", default: "proposed", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "subject_type", "subject_id", "idempotency_key"], name: "index_concierge_agent_proposals_on_scope_and_idempotency_key", unique: true
    t.index ["agent_slug", "subject_type", "subject_id", "state"], name: "index_concierge_agent_proposals_on_scope_and_state"
    t.index ["state", "expires_at"], name: "index_concierge_agent_proposals_on_state_and_expiry"
  end

  create_table "concierge_agent_rule_revisions", force: :cascade do |t|
    t.string "actor"
    t.bigint "agent_rule_id", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.string "enforcement"
    t.string "note"
    t.text "predicate"
    t.string "state"
    t.integer "version", null: false
    t.index ["agent_rule_id", "version"], name: "index_concierge_agent_rule_revisions_on_rule_and_version"
  end

  create_table "concierge_agent_rules", force: :cascade do |t|
    t.datetime "activated_at"
    t.string "agent_slug", null: false
    t.string "approver"
    t.string "author"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "deprecated_at"
    t.text "deprecation_evidence"
    t.datetime "deprecation_proposed_at"
    t.string "enforcement", default: "advisory", null: false
    t.text "predicate"
    t.datetime "proposed_at"
    t.text "provenance"
    t.string "segment"
    t.string "state", default: "proposed", null: false
    t.string "subject_id"
    t.string "subject_type"
    t.bigint "superseded_by_id"
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.index ["agent_slug", "state", "subject_type", "subject_id"], name: "index_concierge_agent_rules_on_scope_and_state"
    t.index ["superseded_by_id"], name: "index_concierge_agent_rules_on_superseded_by"
  end

  create_table "concierge_agent_runs", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.bigint "chat_id"
    t.datetime "created_at", null: false
    t.string "error_class"
    t.integer "input_tokens"
    t.text "memory_ids"
    t.bigint "message_id"
    t.string "model"
    t.integer "output_tokens"
    t.bigint "prompt_message_id"
    t.text "rule_ids_applied"
    t.text "rules"
    t.string "snapshot_digest"
    t.string "status", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "trigger", null: false
    t.text "unknown_rule_ids"
    t.index ["agent_slug", "subject_type", "subject_id", "created_at"], name: "index_concierge_agent_runs_on_scope_and_recency"
  end

  create_table "concierge_budget_ledgers", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.datetime "created_at", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.integer "tokens_spent", default: 0, null: false
    t.datetime "updated_at", null: false
    t.date "window_on", null: false
    t.index ["agent_slug", "subject_type", "subject_id", "window_on"], name: "index_concierge_budget_ledgers_on_scope_window", unique: true
  end

  create_table "concierge_channel_deliveries", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "kind", default: "outreach", null: false
    t.string "payload_digest"
    t.datetime "sent_at", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "unsubscribe_token"
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "subject_type", "subject_id", "sent_at"], name: "index_concierge_deliveries_on_scope_and_sent_at"
    t.index ["subject_type", "subject_id", "sent_at"], name: "index_concierge_deliveries_on_subject_and_sent_at"
    t.index ["unsubscribe_token"], name: "index_concierge_deliveries_on_unsubscribe_token", unique: true
  end

  create_table "concierge_conversations", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.integer "chat_id", null: false
    t.datetime "created_at", null: false
    t.string "grain", default: "account", null: false
    t.datetime "last_reviewed_at"
    t.string "last_snapshot_digest"
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "subject_type", "subject_id"], name: "index_concierge_conversations_on_scope", unique: true
  end

  create_table "concierge_handoffs", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.datetime "created_at", null: false
    t.string "operator"
    t.datetime "released_at"
    t.string "released_by"
    t.datetime "seized_at"
    t.string "state", default: "active", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "subject_type", "subject_id", "state"], name: "index_concierge_handoffs_on_scope_and_state"
  end

  create_table "concierge_memories", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "agent_slug", null: false
    t.text "body"
    t.string "category"
    t.datetime "created_at", null: false
    t.boolean "pinned", default: false, null: false
    t.string "source", default: "agent", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "tier", default: "account", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "subject_type", "subject_id", "active", "category"], name: "index_concierge_memories_on_scope_active_category"
    t.index ["agent_slug", "subject_type", "subject_id", "updated_at"], name: "index_concierge_memories_on_scope_recency"
  end

  create_table "concierge_outreach_preferences", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "frequency", default: "normal", null: false
    t.boolean "opted_out", default: false, null: false
    t.integer "quiet_hours_end"
    t.integer "quiet_hours_start"
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id"], name: "index_concierge_outreach_prefs_on_subject", unique: true
  end

  create_table "concierge_routines", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.string "author", default: "agent", null: false
    t.string "channel"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "instruction", null: false
    t.datetime "next_run_at"
    t.string "schedule", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "subject_type", "subject_id"], name: "index_concierge_routines_on_scope"
    t.index ["enabled", "next_run_at"], name: "index_concierge_routines_on_enabled_and_next_run_at"
  end

  create_table "concierge_slack_cards", force: :cascade do |t|
    t.bigint "agent_proposal_id", null: false
    t.string "agent_slug", null: false
    t.string "channel_id"
    t.datetime "created_at", null: false
    t.text "error"
    t.string "message_ts"
    t.datetime "posted_at"
    t.string "state", default: "posted", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "thread_ts"
    t.datetime "updated_at", null: false
    t.index ["agent_proposal_id"], name: "index_concierge_slack_cards_on_agent_proposal_id", unique: true
    t.index ["agent_slug", "posted_at"], name: "index_concierge_slack_cards_on_agent_and_posted_at"
    t.index ["agent_slug", "subject_type", "subject_id", "created_at"], name: "index_concierge_slack_cards_on_scope_and_recency"
    t.index ["channel_id", "message_ts"], name: "index_concierge_slack_cards_on_message"
    t.index ["channel_id", "thread_ts"], name: "index_concierge_slack_cards_on_thread"
  end

  create_table "inbox_messages", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "delivery_token", null: false
    t.datetime "read_at"
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["delivery_token"], name: "index_inbox_messages_on_delivery_token", unique: true
    t.index ["tenant_id"], name: "index_inbox_messages_on_tenant_id"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "cache_creation_tokens"
    t.integer "cached_tokens"
    t.integer "chat_id", null: false
    t.text "content"
    t.json "content_raw"
    t.datetime "created_at", null: false
    t.integer "input_tokens"
    t.integer "model_id"
    t.integer "output_tokens"
    t.string "role", null: false
    t.text "thinking_signature"
    t.text "thinking_text"
    t.integer "thinking_tokens"
    t.integer "tool_call_id"
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
    t.index ["model_id"], name: "index_messages_on_model_id"
    t.index ["role"], name: "index_messages_on_role"
    t.index ["tool_call_id"], name: "index_messages_on_tool_call_id"
  end

  create_table "models", force: :cascade do |t|
    t.json "capabilities", default: []
    t.integer "context_window"
    t.datetime "created_at", null: false
    t.string "family"
    t.date "knowledge_cutoff"
    t.integer "max_output_tokens"
    t.json "metadata", default: {}
    t.json "modalities", default: {}
    t.datetime "model_created_at"
    t.string "model_id", null: false
    t.string "name", null: false
    t.json "pricing", default: {}
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["family"], name: "index_models_on_family"
    t.index ["provider", "model_id"], name: "index_models_on_provider_and_model_id", unique: true
    t.index ["provider"], name: "index_models_on_provider"
  end

  create_table "tenants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_active_at"
    t.string "name"
    t.string "plan"
    t.datetime "updated_at", null: false
  end

  create_table "tool_calls", force: :cascade do |t|
    t.json "arguments", default: {}
    t.datetime "created_at", null: false
    t.integer "message_id", null: false
    t.string "name", null: false
    t.text "thought_signature"
    t.string "tool_call_id", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_tool_calls_on_message_id"
    t.index ["name"], name: "index_tool_calls_on_name"
    t.index ["tool_call_id"], name: "index_tool_calls_on_tool_call_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "changelog_entries", "tenants"
  add_foreign_key "changelog_entries", "users", column: "author_id"
  add_foreign_key "chats", "models"
  add_foreign_key "inbox_messages", "tenants"
  add_foreign_key "messages", "chats"
  add_foreign_key "messages", "models"
  add_foreign_key "messages", "tool_calls"
  add_foreign_key "tool_calls", "messages"
  add_foreign_key "users", "tenants"
end
