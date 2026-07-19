module Concierge
  # Minimal in-app chat endpoint: takes a customer message for an account and
  # returns the agent's reply. The host renders the widget; this drives it.
  class ChatsController < ApplicationController
    def create
      subject = Concierge.config.account.find_subject(params[:subject_id])
      result = Concierge::Run.reactive(subject, params[:message].to_s)

      if result.ok?
        render json: { reply: result.reply_text }
      else
        render json: { error: "the assistant is unavailable right now" }, status: :service_unavailable
      end
    end
  end
end
