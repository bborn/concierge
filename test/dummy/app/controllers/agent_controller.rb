# Two host affordances that make the agent visible from inside the product.
class AgentController < ApplicationController
  before_action :require_local!, only: :review

  # "Kit, take a look" — the proactive path, on demand. Same code the weekly
  # sweep runs (Run.proactive -> Budget -> Outreach -> ChangeDetector), just
  # without waiting a week for it. Whatever it decides is reported back: a
  # delivery, a draft waiting for a human, or a governed refusal to send.
  def review
    scope  = concierge_scope(:csm)
    result = Concierge::Run.proactive(scope, instruction: instruction)

    return redirect_to(inbox_path, alert: "#{kit} stood down: #{result.reply_text}") if result.suppressed?
    return redirect_to(inbox_path, alert: "#{kit} couldn't run: #{result.error&.message}") unless result.ok?

    Concierge::Budget.new.spend!(scope, result.total_tokens)
    status = Concierge::Outreach.deliver(result, scope, channel: :in_app)
    Concierge::ChangeDetector.mark_reviewed!(scope)

    flash[:agent_run_id] = result.run_record&.id
    redirect_to inbox_path, notice: outcome_of(status)
  end

  # The tool calls the agent made on its most recent turn, read back off the
  # host's own RubyLLM tables.
  #
  # The chat endpoint answers with the final assistant message; a real model's
  # tool calls happen on the messages *before* that one and are persisted by
  # acts_as_chat, so this is where the widget gets them from. Offline there are
  # no persisted messages at all, and this correctly answers with none.
  def activity
    render json: { tool_calls: recent_tool_calls }
  end

  private

  def instruction
    Concierge.config.weekly_review_instruction ||
      "Review this account and reach out if something is worth their attention."
  end

  def outcome_of(status)
    case status
    when :delivered       then "#{kit} reviewed the account and sent you a message."
    when :drafted         then "#{kit} drafted a message — it is waiting for a human in the approval queue."
    when :suppressed      then "#{kit} reviewed the account and decided not to send: #{suppression_reason}."
    when :blocked_by_rule then "#{kit}'s draft was blocked by a guard rule before it could be sent."
    when :no_channel      then "#{kit} had nothing it could reach you on."
    else                       "#{kit} tried to send and the channel failed."
    end
  end

  # Governance answers yes/no, not why. Asking the same two questions it asked
  # turns "suppressed" into something a person watching the demo can believe:
  # the caps are per *customer*, so the last message from either agent counts.
  def suppression_reason
    preference = Concierge::OutreachPreference.for(current_subject)
    return "this account has opted out of outreach" if preference.opted_out

    last = Concierge::ChannelDelivery
           .where(Concierge::Scope.subject_key(current_subject))
           .of_kind("outreach")
           .maximum(:sent_at)

    if last
      "the frequency cap — you asked for “#{preference.frequency}” and the last message " \
        "went out #{helpers.time_ago_in_words(last)} ago"
    else
      "governance said not now (quiet hours)"
    end
  end

  def recent_tool_calls
    chat = Concierge::Conversation.find_by_scope(concierge_scope(agent_slug))&.chat_record
    return [] unless chat

    messages = chat.messages.order(:id).to_a
    last_ask = messages.rindex { |m| m.role.to_s == "user" }
    turn     = last_ask ? messages[(last_ask + 1)..] : messages

    turn.to_a.flat_map { |m| m.tool_calls.map { |call| { name: call.name, arguments: call.arguments } } }
  end

  def agent_slug
    slug = params[:agent].presence || Concierge::Configuration::DEFAULT_AGENT_SLUG
    Concierge.config.agent_declared?(slug) ? slug : Concierge::Configuration::DEFAULT_AGENT_SLUG
  end

  def kit = csm_persona&.name || "Your agent"
end
