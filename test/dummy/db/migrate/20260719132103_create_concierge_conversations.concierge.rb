# This migration comes from concierge (originally 20260101000003)
class CreateConciergeConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_conversations do |t|
      t.string  :subject_type, null: false
      t.string  :subject_id,   null: false
      t.string  :grain,        null: false, default: "account"
      t.integer :chat_id,      null: false
      t.timestamps
    end

    add_index :concierge_conversations,
      [ :subject_type, :subject_id ],
      unique: true,
      name: "index_concierge_conversations_on_subject"
  end
end
