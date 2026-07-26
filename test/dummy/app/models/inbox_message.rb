# The body of an in-app message the agent sent this account, plus whether the
# customer has read it.
#
# Concierge's own audit row keeps a *digest* of the payload, not the payload —
# deliberately, because the delivery ledger is not a message store. Email leaves
# its copy in the recipient's mailbox; in-app leaves nothing unless the host
# keeps it. So the host keeps it, written from the `in_app_broadcaster` hook,
# and joins back to the engine's row by the unsubscribe token that Outreach
# mints *before* delivery and then records the ChannelDelivery under.
#
# The engine's row stays the source of truth for who sent it, when, and under
# which agent. This table only supplies the words and the read state.
class InboxMessage < ApplicationRecord
  belongs_to :tenant

  validates :delivery_token, presence: true, uniqueness: true

  scope :unread, -> { where(read_at: nil) }

  # Called by Concierge for every in-app delivery (see Dummy::ConciergeSetup).
  # A payload with no token cannot be tied back to a delivery row, so it is not
  # something this inbox can show; the engine's operator-reply path is the one
  # caller that sends one, and it has its own surface.
  def self.record!(subject, payload)
    token = payload[:unsubscribe_token] || payload["unsubscribe_token"]
    return nil if token.blank?

    create!(tenant_id: subject.id, delivery_token: token,
            body: (payload[:body] || payload["body"]).to_s)
  end

  def read? = read_at.present?

  def mark_read!
    update!(read_at: Time.current) unless read?
  end

  def replied? = replied_at.present?

  # One exchange, written down in one place. Replying *is* reading — a customer
  # who answered a question has plainly seen it, and making them clear the "new"
  # badge afterwards is the product asking for an acknowledgement it already has.
  #
  # `run_id` is Concierge::AgentRun's id for the turn: which agent answered, what
  # it was told, which rules were in force. The words live here (host retention);
  # the provenance stays the engine's.
  def record_reply!(body:, agent_reply:, run_id: nil, at: Time.current)
    update!(reply_body: body, agent_reply: agent_reply, reply_run_id: run_id,
            replied_at: at, read_at: read_at || at)
  end
end
