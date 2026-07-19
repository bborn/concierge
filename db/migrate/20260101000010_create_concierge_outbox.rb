class CreateConciergeOutbox < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_outbox_items do |t|
      t.string   :subject_type, null: false
      t.string   :subject_id,   null: false
      t.text     :body
      t.string   :channel
      t.string   :kind,         null: false, default: "outreach"
      t.string   :state,        null: false, default: "pending"
      t.timestamps
    end

    add_index :concierge_outbox_items, [ :subject_type, :subject_id, :state ],
      name: "index_concierge_outbox_on_subject_and_state"
  end
end
