module Concierge
  # The host-authorization seam for the engine endpoints that take an account out
  # of the URL — `POST /concierge/accounts/:subject_id/chat` and the handoff
  # endpoints beside it.
  #
  # `/concierge/admin/*` has had `config.authenticate_admin` since Phase 9, and
  # fails closed without it. These endpoints had no equivalent, so any signed-in
  # user of a host app could hand-craft a POST naming somebody else's
  # `subject_id` and be answered with that account's memory, rules and snapshot —
  # a cross-account read straight through an engine surface, which is exactly
  # what §10.12's isolation invariant prevents everywhere else.
  #
  # So: one hook, `config.authorize_subject`, and the same fail-closed default the
  # admin already has. It is handed the controller (the host reads its own
  # session off it) and the resolved Scope, so the answer can be per *(agent,
  # account)* and not only per account — "this user may talk to the CSM but not
  # to billing" is expressible, which it would not be if the hook only saw the
  # subject.
  #
  #   config.authorize_subject = lambda do |controller, scope|
  #     user = User.find_by(id: controller.session[:user_id])
  #     user && user.tenant_id.to_s == scope.subject.id.to_s
  #   end
  #
  # An account that does not exist is refused the same way an account that is not
  # yours is, so a caller who is authorized for neither cannot tell them apart.
  module ScopedEndpoint
    extend ActiveSupport::Concern

    UNCONFIGURED = <<~MESSAGE.freeze
      [Concierge] Refused a request for an account because config.authorize_subject
      is not set. The engine cannot know your app's session shape, so it fails
      closed rather than answer with an account's memory, rules and snapshot to
      whoever asked. Set it in your initializer, next to config.authenticate_admin:

        config.authorize_subject = lambda do |controller, scope|
          user = User.find_by(id: controller.session[:user_id])
          user && user.tenant_id.to_s == scope.subject.id.to_s
        end
    MESSAGE

    included do
      before_action :require_agent!
      before_action :authorize_subject!
    end

    private

    def agent
      @agent ||= Concierge.config.agent(params[:agent].presence || Configuration::DEFAULT_AGENT_SLUG)
    end

    def scope
      @scope ||= Concierge::Scope.new(agent, Concierge.config.account.find_subject(params[:subject_id]))
    end

    def require_agent!
      deny(:not_found, "unknown agent") unless agent
    end

    def authorize_subject!
      hook = Concierge.config.authorize_subject
      return refuse_unconfigured! unless hook

      deny(:forbidden, "not authorized for this account") unless hook.call(self, scope)
    rescue ActiveRecord::RecordNotFound
      deny(:forbidden, "not authorized for this account")
    end

    def refuse_unconfigured!
      Concierge.logger.error(UNCONFIGURED)
      deny(:forbidden, "not authorized for this account")
    end

    # Operator endpoints answer a script with a bare status; the chat endpoint
    # answers a browser's fetch(), so it overrides this to render JSON.
    def deny(status, _message)
      head status
    end
  end
end
