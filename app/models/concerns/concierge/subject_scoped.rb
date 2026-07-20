module Concierge
  # Every Concierge table is keyed to a Subject by the same (subject_type,
  # subject_id) pair. This mixin states that once: +for_subject+ narrows a
  # relation, +find_by_subject+ pulls the single row.
  module SubjectScoped
    extend ActiveSupport::Concern

    included do
      scope :for_subject, ->(subject) { where(subject.key) }
    end

    class_methods do
      def find_by_subject(subject)
        find_by(subject.key)
      end
    end
  end
end
