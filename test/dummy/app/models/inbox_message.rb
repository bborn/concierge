# The body of an in-app message the agent sent this account, plus whether the
# customer has read it and where their reply has got to.
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
#
# ## Persisting is half of an in-app delivery
#
# `Channel::InApp` exists because in-app "must ACTIVELY surface (open a panel /
# raise a badge), not just persist a row" (design §3.5). This model used to do
# only the persisting, which meant the one channel whose entire point is active
# surfacing surfaced nothing: a message that arrived while the customer had the
# app open was invisible until they happened to reload.
#
# So every write here ends in a Turbo Stream broadcast (see InboxBroadcast). The
# callbacks are `after_commit` and unconditional on purpose — surfacing is not a
# thing a caller should be able to forget, and a caller that forgot it would
# leave the engine auditing a delivery that reached nobody.
class InboxMessage < ApplicationRecord
  belongs_to :tenant

  validates :delivery_token, presence: true, uniqueness: true

  scope :unread, -> { where(read_at: nil) }

  after_create_commit  { InboxBroadcast.arrived(self) }
  after_update_commit  { InboxBroadcast.changed(self) }

  # Called by Concierge for every in-app delivery (see Dummy::ConciergeSetup).
  # A payload with no token cannot be tied back to a delivery row, so it is not
  # something this inbox can show; the engine's operator-reply path is the one
  # caller that sends one, and it has its own surface.
  #
  # `actions` is the host's own button vocabulary, resolved by the engine from
  # the keys the agent named (docs/design/message-actions.md) — so it is written
  # down here with the words rather than re-derived at render time. A config edit
  # must not retroactively change what a message delivered last month offered.
  def self.record!(subject, payload)
    token = payload[:unsubscribe_token] || payload["unsubscribe_token"]
    return nil if token.blank?

    create!(tenant_id: subject.id, delivery_token: token,
            body: (payload[:body] || payload["body"]).to_s,
            actions: payload[:actions] || payload["actions"] || [])
  end

  def read? = read_at.present?

  def mark_read!
    update!(read_at: Time.current) unless read?
  end

  # --- The reply, in three states ---------------------------------------------
  # The turn runs in a job now, so "sent" and "answered" are no longer the same
  # instant and the gap between them is a model call long. Each state is a thing
  # the card has to be able to render on a cold page load, because the customer
  # may well not be looking when it changes.

  def replied?        = replied_at.present?
  def reply_failed?   = reply_failed_at.present? && !replied?
  def awaiting_reply? = reply_body.present? && !replied? && !reply_failed?

  # Their words, written down before the job is enqueued rather than passed to
  # it. The job answers the row, not an argument — same reason Inbox::Item quotes
  # the outreach off the delivery record: a request cannot put words into an
  # exchange that the host did not write.
  #
  # Replying *is* reading — a customer who answered a question has plainly seen
  # it, and making them clear the "new" badge afterwards is the product asking
  # for an acknowledgement it already has.
  def start_reply!(body:, at: Time.current)
    update!(reply_body: body, agent_reply: nil, reply_run_id: nil,
            replied_at: nil, reply_failed_at: nil, read_at: read_at || at)
  end

  # One exchange, written down in one place.
  #
  # `run_id` is Concierge::AgentRun's id for the turn: which agent answered, what
  # it was told, which rules were in force. The words live here (host retention);
  # the provenance stays the engine's.
  def complete_reply!(agent_reply:, run_id: nil, at: Time.current)
    update!(agent_reply: agent_reply, reply_run_id: run_id,
            replied_at: at, reply_failed_at: nil)
  end

  # The turn didn't happen. Their words stay — retrying is one click rather than
  # re-typing — but the message goes back to unanswered *and* unread, so the
  # badge that `start_reply!` cleared comes back up. That is the point of the
  # badge: this needs you, and now it needs you again. Telling a customer their
  # question landed when the model never answered it is the failure mode the
  # whole three-state dance exists to avoid.
  def fail_reply!(at: Time.current)
    update!(reply_failed_at: at, replied_at: nil, read_at: nil)
  end
end
