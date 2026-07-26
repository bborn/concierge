module Concierge
  # Minimal in-app chat endpoint: takes a customer message for an account and
  # returns the agent's reply. The host renders the widget; this drives it.
  #
  # An optional +agent+ parameter picks which business function answers; omitted,
  # it is the default +:csm+ agent, so an existing single-agent host's widget
  # keeps posting exactly what it posted before.
  #
  # The account comes out of the URL, so who may name it is the host's call:
  # ScopedEndpoint refuses the turn unless +config.authorize_subject+ says yes.
  class ChatsController < ApplicationController
    include ScopedEndpoint

    def create
      result = Concierge::Run.reactive(scope, params[:message].to_s)

      if result.ok?
        render json: { reply: result.reply_text, agent: scope.agent_slug }
      else
        render json: { error: "the assistant is unavailable right now" }, status: :service_unavailable
      end
    end

    private

    # The widget renders whatever the endpoint says went wrong, so a refusal is
    # JSON like every other answer here rather than an empty body.
    def deny(status, message)
      render json: { error: message }, status: status
    end
  end
end
