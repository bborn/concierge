# What the agents have sent this account in-app, from the customer's side — and,
# since the customer can now answer, what they said back.
#
# Driven off Concierge::ChannelDelivery, one `for_scope` query per (agent, this
# account) — never a widened query that could see another account's, or another
# agent's, deliveries. The engine's row says who sent it, when, and under which
# business function; the host's InboxMessage supplies the words and the read
# state (see that model for why the split exists).
#
# ## An outreach message is not in the chat thread
#
# `Channel::InApp#perform_delivery` hands the payload to the host's
# `in_app_broadcaster` and the engine keeps only a `payload_digest`. The words
# live here. The engine's Conversation maps to the host's ruby_llm chat, which
# holds the *chat* turns and nothing else. So a bare "yes please" posted to the
# chat endpoint would arrive with no antecedent: the model has never seen the
# message it is a reply to, and the honest outcome of that is a confident
# non-sequitur.
#
# Three ways out were on the table. This host takes **(a): the host quotes it**
# — `Item#reply_prompt` carries the outreach text into the turn as quoted
# context, and no engine code changes.
#
#   * **(b), persisting outbound in-app outreach into the conversation**, is the
#     honest one and the dangerous one. Every one of Acme's inbox messages
#     predates any conversation for that (agent, account) — the thread here is
#     opened by the *reply*. Persisting the outreach into it would make the first
#     message an assistant turn, and Anthropic's Messages API requires the first
#     message to be a user one. That is task 5015 exactly (PR #29), which cost a
#     live 400 and a phase of a broken online path, and it is not a hazard worth
#     reintroducing for a demo affordance. It also amends the engine's standing
#     rule that the delivery ledger is not a message store, which is a design
#     change, not a host feature.
#   * **(c), a delivery token the engine resolves**, buys nothing over (a) here.
#     The engine keeps a digest, so it would have to ask the host for the body
#     regardless — a new config hook and a new endpoint parameter to arrive at
#     the same text this file already holds.
#
# What (a) costs, plainly: the transcript shows the customer quoting something
# the agent has no memory of sending, and the thread is not the single record of
# everything said either way. For a demo host whose point is that the *host*
# owns customer-facing words (see InboxMessage), that is the right trade — but
# it is a trade, not a free win.
#
# ## What buttons a message carries
#
# It used to be a question mark in the body: end in one and the message got a
# canned "Yes, help me with that."; otherwise it got a text box and nothing else.
# That was the host pattern-matching prose it did not write, and Bill's
# card-expiry note — which asks nothing and wants a link to the payment settings
# — is exactly where it fell over.
#
# It is now declared, not inferred (docs/design/message-actions.md). This host
# declares a per-agent vocabulary in Dummy::ConciergeSetup, the engine puts that
# vocabulary in the agent's prompt and carries back the keys it picked, and the
# words below render what came back. The affirmative is not special: it is one
# offer among them, whose payload happens to be canned reply text rather than an
# href. The composer stays on every unanswered message either way — a customer
# can always answer in words.
class Inbox
  # One button on one message, as the host declared it and the engine handed it
  # back. `href` and `reply` are this host's own rendering attributes: the engine
  # carried them through untouched and has no opinion about either.
  Action = Struct.new(:key, :label, :href, :reply) do
    def link?  = href.present?
    def reply? = reply.present?
  end

  Item = Struct.new(:delivery, :message, keyword_init: true) do
    def id          = message.id
    def body        = message.body
    def read?       = message.read?
    def replied?    = message.replied?
    def reply_body  = message.reply_body
    def agent_reply = message.agent_reply
    def replied_at  = message.replied_at
    def agent_slug  = delivery.agent_slug
    def kind        = delivery.kind
    def sent_at     = delivery.sent_at

    # Where the reply has got to. The turn runs in a job, so "sent" and
    # "answered" are two states with a model call between them, and a third for
    # the turn that never happened — see InboxMessage.
    def awaiting_reply? = message.awaiting_reply?
    def reply_failed?   = message.reply_failed?

    # The name the customer knows this agent by, falling back to the slug for an
    # agent the host has since removed from its config.
    def agent_name
      Concierge.config.agent(agent_slug)&.playbook&.persona&.name || agent_slug.to_s.titleize
    end

    # The buttons this message carries, in the order the host declared them.
    # Read off the row rather than out of config: what a message offered when it
    # was delivered is history, and a later config edit must not rewrite it.
    #
    # An offer this host no longer understands renders as nothing — the same
    # posture the engine takes toward a key it was never told about.
    def actions
      Array(message.actions).filter_map do |action|
        attrs = action.respond_to?(:with_indifferent_access) ? action.with_indifferent_access : {}
        next if attrs[:label].blank?

        Action.new(attrs[:key], attrs[:label], attrs[:href], attrs[:reply])
      end
    end

    # The customer's words, with the message they answer carried as quoted
    # context — design decision (a), see the class comment.
    #
    # Composed here rather than in the browser because this is where the
    # authority is: the body is the row the host wrote when the engine delivered
    # it, not text a request supplied. A reply cannot put words in the agent's
    # mouth that the agent never sent.
    def reply_prompt(text)
      <<~PROMPT.strip
        The customer is replying in the app to this message you sent them on #{sent_at.strftime('%-d %b')}:

        "#{body}"

        Their reply:

        #{text}
      PROMPT
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

  # One message of this account's, by id — nil for anybody else's. The lookup
  # goes through `items`, so it inherits the per-(agent, account) narrowing above
  # rather than re-deriving it: a controller cannot reach a neighbour's message
  # by asking this for their id, and the agent it answers under comes off the
  # engine's delivery row rather than off the request.
  def find(id)
    items.find { |item| item.id.to_s == id.to_s }
  end

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
