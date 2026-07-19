# This migration comes from concierge (originally 20260101000002)
class CreateConciergeOutreachPreferences < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_outreach_preferences do |t|
      t.string  :subject_type, null: false
      t.string  :subject_id,   null: false
      t.string  :frequency,    null: false, default: "normal"
      t.timestamps
    end

    add_index :concierge_outreach_preferences,
      [ :subject_type, :subject_id ],
      unique: true,
      name: "index_concierge_outreach_prefs_on_subject"
  end
end
