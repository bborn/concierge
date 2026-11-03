class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :bigint do |t|
      t.references :chat, null: false, foreign_key: { to_table: :chats }, type: :bigint
      t.string :role, null: false
      t.text :content
      t.boolean :cache_until_here, null: false, default: false
      t.string :cache_ttl
      t.text :thinking_text
      t.text :thinking_signature

      t.json :citations
      t.json :server_tool_calls
      t.json :raw_content
      t.json :raw_reasoning

      t.string :finish_reason
      t.timestamps
    end
  end
end
