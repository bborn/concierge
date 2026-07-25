# What the agents have sent this account in-app, from the customer's side.
#
# Driven off Concierge::ChannelDelivery, one `for_scope` query per (agent, this
# account) — never a widened query that could see another account's, or another
# agent's, deliveries. The engine's row says who sent it, when, and under which
# business function; the host's InboxMessage supplies the words and the read
# state (see that model for why the split exists).
class Inbox
  Item = Struct.new(:delivery, :message, keyword_init: true) do
    def id         = message.id
    def body       = message.body
    def read?      = message.read?
    def agent_slug = delivery.agent_slug
    def kind       = delivery.kind
    def sent_at    = delivery.sent_at

    # The name the customer knows this agent by, falling back to the slug for an
    # agent the host has since removed from its config.
    def agent_name
      Concierge.config.agent(agent_slug)&.playbook&.persona&.name || agent_slug.to_s.titleize
    end
  end

  def initialize(tenant)
    @tenant  = tenant
    @subject = Concierge.config.account.find_subject(tenant.id)
  end

  def items
    @items ||= build_items
  end

  def unread_count = items.count { |item| !item.read? }

  def any? = items.any?

  private

  def build_items
    deliveries = scopes.flat_map do |scope|
      Concierge::ChannelDelivery.for_scope(scope).where(channel: "in_app").to_a
    end

    bodies = InboxMessage
             .where(tenant_id: @tenant.id, delivery_token: deliveries.map(&:unsubscribe_token))
             .index_by(&:delivery_token)

    deliveries
      .filter_map { |d| (m = bodies[d.unsubscribe_token]) && Item.new(delivery: d, message: m) }
      .sort_by { |item| [ -item.sent_at.to_i, -item.id ] }
  end

  # One scope per declared business function, over this subject only. Listing the
  # agents explicitly is the point: there is no "all agents" query on an
  # AgentScoped table, because widening is exactly the leak the concern prevents.
  def scopes
    Concierge.config.agents.map { |agent| Concierge::Scope.new(agent, @subject) }
  end
end
