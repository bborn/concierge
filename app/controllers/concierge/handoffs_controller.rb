module Concierge
  # Operator endpoints to seize/release a thread and send as a human. Sending as
  # an operator captures the message into the learning loop.
  #
  # A takeover is per (agent, account): taking over the billing thread does not
  # silence the CSM. The optional +agent+ parameter says which one; omitted, it
  # is the default +:csm+ agent.
  class HandoffsController < ApplicationController
    before_action :require_agent!

    def create
      Handoff.seize!(scope, operator: params[:operator])
      head :created
    end

    def message
      Learning.capture(scope, content: params[:body])
      Concierge::Channel::InApp.new(subject: scope.subject).deliver(body: params[:body])
      head :ok
    end

    def destroy
      Handoff.active_for(scope)&.release!
      head :no_content
    end

    private

    def scope
      @scope ||= Concierge::Scope.new(agent, Concierge.config.account.find_subject(params[:subject_id]))
    end

    def agent
      @agent ||= Concierge.config.agent(params[:agent].presence || Configuration::DEFAULT_AGENT_SLUG)
    end

    def require_agent!
      head :not_found unless agent
    end
  end
end
