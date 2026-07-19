# This migration comes from concierge (originally 20260101000008)
class AddReviewTrackingToConversations < ActiveRecord::Migration[7.1]
  def change
    add_column :concierge_conversations, :last_snapshot_digest, :string
    add_column :concierge_conversations, :last_reviewed_at, :datetime
  end
end
