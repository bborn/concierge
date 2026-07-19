# This migration comes from concierge (originally 20260101000004)
class CreateConciergeChannelDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_channel_deliveries do |t|
      t.string   :subject_type, null: false
      t.string   :subject_id,   null: false
      t.string   :channel,      null: false
      t.string   :kind,         null: false, default: "outreach"
      t.datetime :sent_at,      null: false
      t.string   :unsubscribe_token
      t.string   :payload_digest
      t.timestamps
    end

    add_index :concierge_channel_deliveries,
      [ :subject_type, :subject_id, :sent_at ],
      name: "index_concierge_deliveries_on_subject_and_sent_at"
    add_index :concierge_channel_deliveries, :unsubscribe_token, unique: true,
      name: "index_concierge_deliveries_on_unsubscribe_token"
  end
end
