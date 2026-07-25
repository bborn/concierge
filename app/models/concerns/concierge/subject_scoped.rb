module Concierge
  # Every Concierge table is keyed to a Subject by the same (subject_type,
  # subject_id) pair. This mixin states that once: +for_subject+ narrows a
  # relation, +find_by_subject+ pulls the single row.
  #
  # Under the (Agent × Subject) identity model (design §10.1) the key gains a
  # dimension, and +for_scope+ is the form every call site moves to. It takes
  # anything that answers +#key+ — a Concierge::Spike::Scope (agent + subject) or
  # a bare Subject — so a caller that has no agent dimension yet still works.
  module SubjectScoped
    extend ActiveSupport::Concern

    included do
      scope :for_subject, ->(subject) { where(subject.key) }
      scope :for_scope,   ->(scope) { where(scope.key) }
    end

    class_methods do
      def find_by_subject(subject)
        find_by(subject.key)
      end

      def find_by_scope(scope)
        find_by(scope.key)
      end
    end
  end
end
