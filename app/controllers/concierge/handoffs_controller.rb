module Concierge
  # Operator endpoints to seize/release a thread and send as a human. Sending as
  # an operator captures the message into the learning loop.
  #
  # A takeover is per (agent, account): taking over the billing thread does not
  # silence the CSM. The optional +agent+ parameter says which one; omitted, it
  # is the default +:csm+ agent.
  #
  # These are the sharpest endpoints in the engine — seizing a thread speaks to a
  # customer as your company — so they sit behind the same host authorization
  # hook the chat endpoint does (+config.authorize_subject+), and refuse without
  # one. A host whose operator console is staff-only checks for that in the hook:
  # it is handed the controller, so +controller.request.path+ and its own session
  # are both in reach.
  class HandoffsController < ApplicationController
    include ScopedEndpoint

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
  end
end
