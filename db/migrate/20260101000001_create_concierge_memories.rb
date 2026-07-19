class CreateConciergeMemories < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_memories do |t|
      t.string  :subject_type, null: false
      t.string  :subject_id,   null: false
      t.string  :tier,         null: false, default: "account"
      t.text    :body
      t.string  :category
      t.string  :source,       null: false, default: "agent"
      t.boolean :pinned,       null: false, default: false
      t.boolean :active,       null: false, default: true
      t.timestamps
    end

    add_index :concierge_memories,
      [ :subject_type, :subject_id, :active, :category ],
      name: "index_concierge_memories_on_subject_active_category"
    add_index :concierge_memories,
      [ :subject_type, :subject_id, :updated_at ],
      name: "index_concierge_memories_on_subject_recency"
  end
end
