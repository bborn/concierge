module Concierge
  # The two endpoints a real Slack app needs (design §10.7). Not an incoming
  # webhook: a webhook can post a message but cannot tell you *who clicked*, and an
  # approval whose approver is unknown is not maker-checked.
  #
  #   POST /concierge/slack/events        the Events API (URL handshake, thread replies)
  #   POST /concierge/slack/interactions  interactivity (buttons, modal submissions)
  #
  # Both do exactly three things: verify the signature, hand the payload to
  # Concierge::Slack::Intake, and answer Slack quickly. All policy — maker-checker,
  # the gate, the precondition re-check, the guard rules — is in
  # Concierge::ApprovalIntake, which this controller reaches through the intake
  # adapter. A surface holds a transport and no policy.
  #
  # Fails closed: with no signing secret configured there is no way to know a
  # request came from Slack, so the endpoints do not exist (404) rather than
  # trusting the body.
  class SlackController < ApplicationController
    # Slack does not carry a CSRF token; the request signature is the
    # authentication, and it is stronger than one. Verified below on every action
    # before anything is read out of the payload.
    skip_forgery_protection

    before_action :require_slack_configured!
    before_action :verify_slack_signature!

    def events
      result = Concierge::Slack::Intake.handle_event(payload)
      respond_with_result(result)
    end

    def interactions
      result = Concierge::Slack::Intake.handle(interaction_payload)
      respond_with_result(result)
    end

    private

    def require_slack_configured!
      head :not_found unless Concierge::Slack.configured?
    end

    # Step 1 of the handler order, before a single write. The *raw* body is what
    # Slack signed — a re-serialized params hash is not the same bytes.
    def verify_slack_signature!
      Concierge::Slack::Signature.verify!(body: request.raw_post, headers: request.headers)
    rescue Concierge::Slack::SignatureError => e
      Concierge.logger&.warn("[concierge] rejected an unsigned Slack request: #{e.message}")
      head :unauthorized
    end

    # Slack answers a 200 with an empty body by leaving the message alone, and
    # treats a JSON body as instructions (a modal's validation errors). Anything
    # else it shows the user as an error, so there is no third case.
    def respond_with_result(result)
      return render json: result.body if result.respond_to?(:json?) && result.json?

      head :ok
    end

    # The Events API posts JSON. Rails has already parsed it, but `request.params`
    # carries routing keys too, so read the parsed body.
    def payload
      request.request_parameters
    end

    # Interactivity is form-encoded with the JSON in a `payload` field.
    def interaction_payload
      JSON.parse(params[:payload].to_s)
    rescue JSON::ParserError => e
      Concierge.logger&.warn("[concierge] unparseable Slack interaction payload: #{e.message}")
      {}
    end
  end
end
