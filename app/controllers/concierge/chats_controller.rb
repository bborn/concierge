module Concierge
  # Minimal in-app chat endpoint: takes a customer message for an account and
  # returns the agent's reply. The host renders the widget; this drives it.
  #
  # An optional +agent+ parameter picks which business function answers; omitted,
  # it is the default +:csm+ agent, so an existing single-agent host's widget
  # keeps posting exactly what it posted before.
  class ChatsController < ApplicationController
    def create
      return render json: { error: "unknown agent" }, status: :not_found unless agent

      subject = Concierge.config.account.find_subject(params[:subject_id])
      scope   = Concierge::Scope.new(agent, subject)
      result  = Concierge::Run.reactive(scope, params[:message].to_s)

      if result.ok?
        render json: { reply: result.reply_text, agent: scope.agent_slug }
      else
        render json: { error: "the assistant is unavailable right now" }, status: :service_unavailable
      end
    end

    private

    def agent
      @agent ||= Concierge.config.agent(params[:agent].presence || Configuration::DEFAULT_AGENT_SLUG)
    end
  end
end
