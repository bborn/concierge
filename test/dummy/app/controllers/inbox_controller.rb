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
  def reply
    item = inbox.find(params[:id])
    return head(:not_found) unless item

    text = params[:body].to_s.strip
    return redirect_to(inbox_path, alert: "Nothing to send.") if text.blank?

    answer(item, text)
  end

  private

  def answer(item, text)
    scope  = concierge_scope(item.agent_slug)
    result = Concierge::Run.reactive(scope, item.reply_prompt(text))

    unless result.ok?
      # The message stays unread and unanswered, so the customer can try again
      # rather than being told their question landed when it did not.
      return redirect_to inbox_path,
                         alert: "#{item.agent_name} couldn't answer just now. Your message wasn't sent."
    end

    item.message.record_reply!(body: text, agent_reply: result.reply_text,
                               run_id: result.run_record&.id)
    redirect_to inbox_path, notice: "#{item.agent_name} replied."
  end
end
