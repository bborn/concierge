# The host app's own product tables. Nothing in here is Concierge's: a changelog
# is what Acme sells, and the inbox is where the host chose to keep the body of
# an in-app message. The engine's audit row (concierge_channel_deliveries) keeps
# only a digest of a payload on purpose, so a host that wants to *show* the
# customer what was sent has to store it — which is what in_app_broadcaster is
# for. The two rows are joined by the delivery's unsubscribe token, which
# Outreach mints before delivery and records under.
class CreateAcmeProduct < ActiveRecord::Migration[8.1]
  def change
    create_table :changelog_entries do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :author, foreign_key: { to_table: :users }
      t.string   :title, null: false
      t.text     :body
      t.string   :status, null: false, default: "draft"
      t.datetime :published_at
      t.timestamps

      t.index [ :tenant_id, :status ]
    end

    create_table :inbox_messages do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string   :delivery_token, null: false
      t.text     :body
      t.datetime :read_at
      t.timestamps

      t.index :delivery_token, unique: true
    end
  end
end
