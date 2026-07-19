# This migration comes from concierge (originally 20260101000005)
class AddGovernanceToConciergeOutreachPreferences < ActiveRecord::Migration[7.1]
  def change
    add_column :concierge_outreach_preferences, :opted_out, :boolean, null: false, default: false
    add_column :concierge_outreach_preferences, :quiet_hours_start, :integer
    add_column :concierge_outreach_preferences, :quiet_hours_end, :integer
  end
end
