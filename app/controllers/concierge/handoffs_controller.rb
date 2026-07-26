module Concierge
  # Operator endpoints to seize/release a thread and send as a human. Sending as
  # an operator captures the message into the learning loop.
  #
  # A takeover is per (agent, account): taking over the billing thread does not
  # silence the CSM. The optional +agent+ parameter says which one; omitted, it
  # is the default +:csm+ agent.
  #
  # These are the sharpest endpoints in the engine — seizing a thread speaks to a
  # customer as your company, and what an operator sends is captured as pinned,
  # human-sourced memory that outweighs the agent's own notes in the next prompt.
  # So they ask their own question of the host, +config.authorize_operator+ ("are
  # you staff, and is this account in your book"), and refuse without it.
  #
  # Not +config.authorize_subject+, which the chat endpoint asks: that one is "is
  # this account yours", and a customer answers yes about their own account.
  # Sharing it let a signed-in customer seize their own thread and message
  # themselves as support. Two questions, two hooks, and the second does not
  # inherit an answer to the first (see Concierge::ScopedEndpoint).
  #
  # A third question, +config.operator_actor+, answers *who* is acting. It used
  # to be +params[:operator]+: the caller named themselves, so a staff member who
  # had passed the gate could seize a thread as a colleague or as the CEO, and
  # the customer would be told that name. The operator of record is now the
  # host's answer, and the request parameter is not read at all.
  class HandoffsController < ApplicationController
    include ScopedEndpoint

    authorize_with :operator

    def create
      Handoff.seize!(scope, operator: operator)
      head :created
    end

    def message
      # The same identity authors the capture: a correction that becomes a
      # proposed rule carries who made it, exactly as the Slack intake does.
      Learning.capture(scope, content: params[:body], author: operator)
      Concierge::Channel::InApp.new(subject: scope.subject).deliver(body: params[:body])
      head :ok
    end

    def destroy
      Handoff.active_for(scope)&.release!
      head :no_content
    end
  end
end
