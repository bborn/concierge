module Concierge
  # Tables keyed to a Subject alone, by the same (subject_type, subject_id) pair
  # the engine has always used. Under the (Agent × Subject) identity model this
  # is the *narrower* of the two scoping concerns: only rows that belong to the
  # customer rather than to any one agent stay here — today just
  # +concierge_outreach_preferences+, because "email me less" is the customer's
  # preference about being contacted at all, not one agent's private setting
  # (design §10.1, confirmed by the step-0 spike §A2).
  #
  # Everything else includes AgentScoped, which layers the agent dimension on top.
  module SubjectScoped
    extend ActiveSupport::Concern

    included do
      scope :for_subject, ->(subject) { where(Scope.subject_key(subject)) }

      # Handed a Scope, this narrows by its subject half only. There is no agent
      # dimension on this table to narrow by, and inventing one would be a lie.
      scope :for_scope, ->(scope) { where(Scope.subject_key(scope)) }
    end

    class_methods do
      def find_by_subject(subject)
        find_by(Scope.subject_key(subject))
      end

      def find_by_scope(scope)
        find_by(Scope.subject_key(scope))
      end
    end
  end
end
