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

ActiveRecord::Schema[8.1].define(version: 2026_07_19_133147) do
  create_table "chats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "model_id"
    t.datetime "updated_at", null: false
    t.index ["model_id"], name: "index_chats_on_model_id"
  end

  create_table "concierge_budget_ledgers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.integer "tokens_spent", default: 0, null: false
    t.datetime "updated_at", null: false
    t.date "window_on", null: false
    t.index ["subject_type", "subject_id", "window_on"], name: "index_concierge_budget_ledgers_on_subject_window", unique: true
  end

  create_table "concierge_channel_deliveries", force: :cascade do |t|
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "kind", default: "outreach", null: false
    t.string "payload_digest"
    t.datetime "sent_at", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "unsubscribe_token"
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id", "sent_at"], name: "index_concierge_deliveries_on_subject_and_sent_at"
    t.index ["unsubscribe_token"], name: "index_concierge_deliveries_on_unsubscribe_token", unique: true
  end

  create_table "concierge_conversations", force: :cascade do |t|
    t.integer "chat_id", null: false
    t.datetime "created_at", null: false
    t.string "grain", default: "account", null: false
    t.datetime "last_reviewed_at"
    t.string "last_snapshot_digest"
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id"], name: "index_concierge_conversations_on_subject", unique: true
  end

  create_table "concierge_memories", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "body"
    t.string "category"
    t.datetime "created_at", null: false
    t.boolean "pinned", default: false, null: false
    t.string "source", default: "agent", null: false
    t.string "subject_id", null: false
    t.string "subject_type", null: false
    t.string "tier", default: "account", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id", "active", "category"], name: "index_concierge_memories_on_subject_active_category"
    t.index ["subject_type", "subject_id", "updated_at"], name: "index_concierge_memories_on_subject_recency"
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
    t.index ["enabled", "next_run_at"], name: "index_concierge_routines_on_enabled_and_next_run_at"
    t.index ["subject_type", "subject_id"], name: "index_concierge_routines_on_subject"
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

  add_foreign_key "chats", "models"
  add_foreign_key "messages", "chats"
  add_foreign_key "messages", "models"
  add_foreign_key "messages", "tool_calls"
  add_foreign_key "tool_calls", "messages"
  add_foreign_key "users", "tenants"
end
