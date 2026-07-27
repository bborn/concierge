# What the agent sent *you*, and what you said back. Proactive outreach that only
# ever showed up in the engine admin is outreach the customer never saw; outreach
# the customer can only dismiss is a question the agent asked into a void.
class InboxController < ApplicationController
  def index
    @items = inbox.items
  end

  def read
    current_tenant.inbox_messages.find(params[:id]).mark_read!
    redirect_to inbox_path
  end

  def read_all
    current_tenant.inbox_messages.unread.find_each(&:mark_read!)
    redirect_to inbox_path, notice: "Inbox cleared."
  end

  # Answering an agent that asked something.
  #
  # `Concierge::Run.reactive(scope, message)` is the whole body of the engine's
  # own chat endpoint (Concierge::ChatsController#create) — the widget's path,
  # one layer below the HTTP wrapper, and the same call AgentController#review
  # already makes for the proactive half. There is no second chat backend here:
  # no second prompt assembly, no second RubyLLM driver, no second provenance
  # row.
  #
  # It is driven from the host rather than by posting to that endpoint from the
  # browser for two reasons the endpoint cannot serve:
  #
  #   * **The agent is not the request's to choose.** Bill and Kit have different
  #     personas, tool scopes and authority envelopes, and the endpoint takes the
  #     agent as a parameter. Here it comes off the ChannelDelivery row this
  #     message was delivered under, resolved inside this account's own scope —
  #     so a reply to Bill reaches :billing because of what the engine recorded,
  #     not because of what a form field said. `params[:agent]` is not read.
  #   * **Marking read and recording the exchange are the host's writes.** They
  #     have to happen with the turn, not in a follow-up request that can fail
  #     on its own and leave an answered question still flagged "new".
  #
  # ## The turn does not happen in this request
  #
  # It used to. Offline that reads as instant, because Dummy::ScriptedChat
  # answers in microseconds; against a real provider it is a customer watching a
  # form post spin for as long as the model takes to think. So this writes their
  # words down, hands the turn to a job, and answers immediately with the card in
  # its "sent, waiting" state. The answer arrives over the same Turbo Stream that
  # pushes the agent's unprompted messages — which is the honest version of the
  # symmetry: an agent's words reach an open page the same way whether the
  # customer asked for them or not.
  #
  # The pending state is a persisted one (InboxMessage), not a spinner drawn in
  # the browser, so a reload, a second tab, or a phone in another pocket all show
  # the same thing.
  def reply
    item = inbox.find(params[:id])
    return head(:not_found) unless item

    text = params[:body].to_s.strip
    return redirect_to(inbox_path, alert: "Nothing to send.") if text.blank?
    return redirect_to(inbox_path, alert: "#{item.agent_name} already answered that.") if item.replied?

    ask(item, text)
  end

  private

  def ask(item, text)
    item.message.start_reply!(body: text)
    InboxReplyJob.perform_later(item.message)

    redirect_to inbox_path, notice: "Sent — #{item.agent_name} is replying."
  rescue StandardError => e
    # The queue is down, so nothing will ever pick this up. Better to say so now
    # than to leave the customer watching a card that will never resolve.
    Rails.logger.error("[acme] could not enqueue reply for message #{item.id}: #{e.class}")
    item.message.fail_reply!
    redirect_to inbox_path,
                alert: "#{item.agent_name} couldn't answer just now. Your message wasn't sent."
  end
end
