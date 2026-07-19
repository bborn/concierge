module Concierge
  # Operator endpoints to seize/release a thread and send as a human. Sending as
  # an operator captures the message into the learning loop.
  class HandoffsController < ApplicationController
    def create
      Handoff.seize!(subject, operator: params[:operator])
      head :created
    end

    def message
      Learning.capture(subject, content: params[:body])
      Concierge::Channel::InApp.new(subject: subject).deliver(body: params[:body])
      head :ok
    end

    def destroy
      Handoff.active_for(subject)&.release!
      head :no_content
    end

    private

    def subject
      Concierge.config.account.find_subject(params[:subject_id])
    end
  end
end
