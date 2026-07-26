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
  # ## Two endpoints, two questions
  #
  # They are not the same question, so they do not share a hook:
  #
  #   chat     "is this account yours?"                  config.authorize_subject
  #   handoff  "are you staff, and is this account       config.authorize_operator
  #             in your book?"
  #
  # One hook for both looked cheaper — the controller is handed over, so a host
  # *could* write the staff clause inside it. But the answer a host reaches for
  # first is a tenant match:
  #
  #   config.authorize_subject = lambda do |controller, scope|
  #     user = User.find_by(id: controller.session[:user_id])
  #     user && user.tenant_id.to_s == scope.subject.id.to_s
  #   end
  #
  # ...which is right for the chat endpoint and quietly wrong for the operator
  # ones: a customer answers yes about their own account, and so may seize their
  # own thread and message themselves as support — landing pinned, human-sourced
  # memory, weighted ahead of the agent's own notes in the next prompt and a
  # candidate for a behavioral rule. The hole is opened by *omission*, which is
  # why `authorize_operator` does not fall back to `authorize_subject` when
  # unset. A host that has not answered the second question has not answered it.
  #
  # Each endpoint declares which one it asks:
  #
  #   class HandoffsController < ApplicationController
  #     include ScopedEndpoint
  #     authorize_with :operator
  #   end
  #
  # Both hooks are handed the controller (the host reads its own session off it)
  # and the resolved Scope, so the answer can be per *(agent, account)* and not
  # only per account — "this user may talk to the CSM but not to billing", or
  # "this operator covers enterprise accounts only", are expressible, which they
  # would not be if a hook only saw the subject.
  #
  # An account that does not exist is refused the same way an account that is not
  # yours is, so a caller who is authorized for neither cannot tell them apart.
  module ScopedEndpoint
    extend ActiveSupport::Concern

    # The questions an endpoint may ask, and the config hook that answers each.
    HOOKS = { subject: :authorize_subject, operator: :authorize_operator }.freeze

    UNCONFIGURED_SUBJECT = <<~MESSAGE.freeze
      [Concierge] Refused a request for an account because config.authorize_subject
      is not set. The engine cannot know your app's session shape, so it fails
      closed rather than answer with an account's memory, rules and snapshot to
      whoever asked. Set it in your initializer, next to config.authenticate_admin:

        config.authorize_subject = lambda do |controller, scope|
          user = User.find_by(id: controller.session[:user_id])
          user && user.tenant_id.to_s == scope.subject.id.to_s
        end
    MESSAGE

    UNCONFIGURED_OPERATOR = <<~MESSAGE.freeze
      [Concierge] Refused an operator request because config.authorize_operator is
      not set. Seizing a thread speaks to a customer as your company, so the
      question is "are you staff, and is this account in your book" — not
      config.authorize_subject's "is this account yours", which a customer answers
      yes about their own account. It is a separate hook for that reason, and does
      not inherit that one. Set it in your initializer:

        config.authorize_operator = lambda do |controller, scope|
          staff = Staff.find_by(id: controller.session[:staff_id])
          staff && staff.covers?(scope.subject.id)
        end
    MESSAGE

    UNCONFIGURED = { subject: UNCONFIGURED_SUBJECT, operator: UNCONFIGURED_OPERATOR }.freeze

    included do
      # No default: a controller that mounts this seam and forgets to say which
      # question it asks gets the safe answer, not the permissive one.
      class_attribute :concierge_question, instance_writer: false, default: nil

      before_action :require_agent!
      before_action :authorize_scope!
    end

    class_methods do
      # Declare which host question guards this endpoint — :subject for a
      # customer acting as their own account, :operator for staff acting on it.
      def authorize_with(question)
        unless HOOKS.key?(question)
          raise ArgumentError, "unknown authorization question #{question.inspect} (expected :subject or :operator)"
        end

        self.concierge_question = question
      end
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

    def authorize_scope!
      return refuse_undeclared! unless concierge_question

      hook = Concierge.config.public_send(HOOKS.fetch(concierge_question))
      return refuse_unconfigured! unless hook

      deny(:forbidden, "not authorized for this account") unless hook.call(self, scope)
    rescue ActiveRecord::RecordNotFound
      deny(:forbidden, "not authorized for this account")
    end

    def refuse_unconfigured!
      Concierge.logger.error(UNCONFIGURED.fetch(concierge_question))
      deny(:forbidden, "not authorized for this account")
    end

    # Reachable only from a bug in the engine, or from an app that mounted this
    # concern itself, so it says which — and still refuses.
    def refuse_undeclared!
      Concierge.logger.error(
        "[Concierge] #{self.class.name} includes ScopedEndpoint without declaring " \
        "authorize_with(:subject) or authorize_with(:operator), so the request was refused."
      )
      deny(:forbidden, "not authorized for this account")
    end

    # Operator endpoints answer a script with a bare status; the chat endpoint
    # answers a browser's fetch(), so it overrides this to render JSON.
    def deny(status, _message)
      head status
    end
  end
end
