# This migration comes from concierge (originally 20260101000006)
class CreateConciergeRoutines < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_routines do |t|
      t.string   :subject_type, null: false
      t.string   :subject_id,   null: false
      t.string   :schedule,     null: false
      t.text     :instruction,  null: false
      t.string   :channel
      t.string   :author,       null: false, default: "agent"
      t.datetime :next_run_at
      t.boolean  :enabled,      null: false, default: true
      t.timestamps
    end

    add_index :concierge_routines, [ :enabled, :next_run_at ],
      name: "index_concierge_routines_on_enabled_and_next_run_at"
    add_index :concierge_routines, [ :subject_type, :subject_id ],
      name: "index_concierge_routines_on_subject"
  end
end
