class CreateRubyLlmRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :ruby_llm_models, id: :bigint do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff
      t.datetime :unlisted_at

      t.json :modalities, default: {}
      t.json :capabilities, default: []
      t.json :pricing, default: {}
      t.json :metadata, default: {}

      t.timestamps

      t.index [ :provider, :model_id ], unique: true
      t.index :provider
      t.index :family
    end

    create_table :ruby_llm_tool_calls, id: :bigint do |t|
      t.references :message, polymorphic: true, null: false, type: :bigint, index: false
      t.references :result, polymorphic: true, type: :bigint, index: false
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature
      t.string :approval
      t.boolean :remote, default: false, null: false

      t.json :arguments, default: {}
      t.json :mcp_state
      t.json :mcp_result

      t.timestamps

      t.index [ :message_type, :message_id ]
      t.index [ :result_type, :result_id ]
      t.index :tool_call_id, unique: true
      t.index :name
    end

    create_table :ruby_llm_mcp_credentials, id: :bigint do |t|
      t.references :owner, polymorphic: true, type: :bigint
      t.string :key, null: false
      t.text :data
      t.timestamps

      t.index :key, unique: true
    end

    create_table :ruby_llm_usages, id: :bigint do |t|
      t.references :chat, polymorphic: true, type: :bigint, index: false
      t.references :message, polymorphic: true, type: :bigint, index: false
      t.references :owner, polymorphic: true, type: :bigint, index: false
      t.string :operation, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :status, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.integer :thinking_tokens

      t.json :server_tool_use

      t.decimal :input_cost, precision: 16, scale: 10
      t.decimal :output_cost, precision: 16, scale: 10
      t.decimal :cache_read_cost, precision: 16, scale: 10
      t.decimal :cache_write_cost, precision: 16, scale: 10
      t.decimal :thinking_cost, precision: 16, scale: 10
      t.decimal :total_cost, precision: 16, scale: 10
      t.timestamps

      t.index [ :chat_type, :chat_id ]
      t.index [ :message_type, :message_id ]
      t.index [ :owner_type, :owner_id ]
      t.index :status
      t.check_constraint "operation IN ('chat', 'embedding', 'moderation', 'image', 'speech', 'transcription', 'ocr', 'rerank', 'judgment', 'video', 'research')"
      t.check_constraint "status IN ('pending', 'succeeded', 'failed', 'cancelled')"
    end

    create_table :ruby_llm_batches, id: :bigint do |t|
      t.string :provider_batch_id, null: false
      t.string :provider, null: false
      t.string :status, null: false
      t.string :raw_status
      t.boolean :completed, null: false, default: false
      t.string :chat_type
      t.string :batch_protocol

      t.json :chat_ids, default: []
      t.json :request_counts
      t.json :reported_cost

      t.timestamps

      t.index [ :provider, :provider_batch_id ], unique: true
      t.index :status
    end

    create_table :ruby_llm_provider_files, id: :bigint do |t|
      t.string :blob_key, null: false
      t.string :provider, null: false
      t.string :account, null: false
      t.text :file_id, null: false
      t.datetime :expires_at
      t.timestamps

      t.index [ :blob_key, :provider, :account ], unique: true, name: "index_ruby_llm_provider_files_uniqueness"
    end
  end
end
