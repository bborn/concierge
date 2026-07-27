# One inbox reply, off the request.
#
# The job is handed the row, not the words. The customer's text was written to
# `reply_body` before this was enqueued, and the message being answered comes off
# the engine's ChannelDelivery — so the whole prompt is assembled from records
# the host wrote, and a replayed or hand-crafted job argument cannot put words
# into the exchange. It is the same reasoning as Inbox::Item#reply_prompt
# quoting the outreach off the delivery row instead of trusting a form field.
#
# Which agent answers is likewise the delivery row's to say, resolved through
# `Inbox#find` — the one method that narrows to (agent, this account). A job
# running outside a request has no session to fall back on, which makes that
# narrowing more load-bearing here than in the controller, not less.
class InboxReplyJob < ApplicationJob
  queue_as :default

  # A row that has since been deleted is not a failure worth retrying.
  discard_on ActiveJob::DeserializationError

  def perform(message)
    item = Inbox.new(message.tenant).find(message.id)
    return unless item&.awaiting_reply?

    answer(item, message)
  end

  private

  def answer(item, message)
    scope  = Concierge::Scope.new(Concierge.config.agent(item.agent_slug),
                                  Concierge.config.account.find_subject(message.tenant_id))
    result = Concierge::Run.reactive(scope, item.reply_prompt(message.reply_body))

    if result.ok?
      message.complete_reply!(agent_reply: result.reply_text, run_id: result.run_record&.id)
    else
      # Not raised, so the job does not retry. A model that declined or errored
      # is a thing to tell the customer about — the card says so and keeps their
      # words — rather than something to quietly attempt four more times against
      # a token budget they are paying for.
      Rails.logger.warn("[acme] reply turn failed for message #{message.id}: #{result.error&.message}")
      message.fail_reply!
    end
  end
end
