# The buttons a message carries, as the engine resolved them.
#
# They are stored here rather than re-derived at render time on purpose: the
# vocabulary is host config and config changes, so a message delivered in March
# must keep showing the offer it was actually delivered with. Deriving it live
# would silently rewrite the past every time the host edited its config.
#
# Every value in here originated in this host's own `Concierge.configure` block
# — the agent named keys, the engine resolved them against what was declared —
# so nothing model-authored reaches a link or a label. See
# docs/design/message-actions.md.
class AddActionsToInboxMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :inbox_messages, :actions, :json
  end
end
