class CreateConciergeHandoffs < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_handoffs do |t|
      t.string   :subject_type, null: false
      t.string   :subject_id,   null: false
      t.string   :operator
      t.string   :state,        null: false, default: "active"
      t.datetime :seized_at
      t.datetime :released_at
      t.timestamps
    end

    add_index :concierge_handoffs, [ :subject_type, :subject_id, :state ],
      name: "index_concierge_handoffs_on_subject_and_state"
  end
end
