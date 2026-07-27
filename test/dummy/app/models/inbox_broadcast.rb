# Where "actively surface" actually happens.
#
# `Concierge::Channel::InApp` hands the payload to the host and stops. Everything
# past that — a stream to push down, a target to push at, a partial to render —
# is the host's, which is why the engine ships no default broadcaster: it keeps a
# digest, not the words, so it could not render this card even if it wanted to.
#
# ## One stream per account, and the account is never in the request
#
# The stream is `turbo_stream_from current_tenant`, signed by Turbo. Dana's page
# renders a signature for Acme's stream and Hank's renders one for Globex's;
# neither browser can forge the other's, and nothing here ever takes a tenant id
# from a parameter. The socket itself refuses anonymous connections
# (ApplicationCable::Connection), so the two gates are "are you signed in" and
# "did a page of yours render this stream name".
#
# ## Rendering goes back through Inbox
#
# The card needs the engine's ChannelDelivery (who sent it, when, which business
# function) as well as the host's row, and `Inbox#find` is the one place that
# joins them under a per-(agent, this account) narrowing. Rebuilding the Item
# here rather than passing one in means the broadcast path inherits that
# narrowing instead of re-deriving it — a message this account may not see is a
# message this account may not be pushed, and one method decides both.
#
# Broadcasts are synchronous rather than `*_later_to`. A demo host has one
# message to render and no queue worth the indirection, and a broadcast that
# lands in a job is a broadcast that can be silently swallowed by a queue nobody
# is running — which is exactly the "delivered, to nobody" failure this whole
# change is about.
module InboxBroadcast
  module_function

  # A new message from an agent. Prepend it to whatever inbox page is open, drop
  # the empty state if that is what was on screen, and raise the badge on every
  # other page of this account's.
  def arrived(message)
    item = item_for(message)
    return unless item

    Turbo::StreamsChannel.broadcast_prepend_to(
      message.tenant, target: "inbox-messages",
      partial: "inbox/message", locals: { item: item }
    )
    Turbo::StreamsChannel.broadcast_remove_to(message.tenant, target: "inbox-empty")
    badge(message.tenant)
  end

  # A message that changed under the customer: marked read, a reply started, an
  # answer landed, a turn failed. Same card, replaced in place.
  def changed(message)
    item = item_for(message)
    return unless item

    Turbo::StreamsChannel.broadcast_replace_to(
      message.tenant, target: ActionView::RecordIdentifier.dom_id(message),
      partial: "inbox/message", locals: { item: item }
    )
    badge(message.tenant)
  end

  def badge(tenant)
    Turbo::StreamsChannel.broadcast_replace_to(
      tenant, target: "inbox-badge",
      partial: "shared/inbox_badge", locals: { count: Inbox.new(tenant).unread_count }
    )
  end

  # nil for a row the engine has no delivery for — a message written by hand, or
  # one whose ledger entry was rolled back because the send failed. Nothing to
  # say about who sent it means nothing to render, so nothing is pushed rather
  # than a half-built card.
  def item_for(message)
    Inbox.new(message.tenant).find(message.id)
  end
end
