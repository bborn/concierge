module Concierge
  # Gates proactive runs on "something changed since we last looked," so idle
  # accounts don't burn budget (design §4.3). Compares the current account
  # Snapshot digest to the one stored when we last reviewed the account.
  class ChangeDetector
    def self.changed?(subject)
      new(subject).changed?
    end

    def self.mark_reviewed!(subject, at: nil)
      new(subject).mark_reviewed!(at: at)
    end

    def initialize(subject)
      @subject = subject
    end

    def changed?
      conversation = Conversation.for_subject(@subject)
      return true if conversation.nil? || conversation.last_snapshot_digest.blank?

      conversation.last_snapshot_digest != current_digest
    end

    def mark_reviewed!(at: nil)
      conversation = Conversation.for_subject(@subject) || ChatResolver.call(@subject) && Conversation.for_subject(@subject)
      conversation&.update!(last_snapshot_digest: current_digest, last_reviewed_at: at || Time.current)
    end

    private

    def current_digest
      @current_digest ||= Snapshot.for(@subject).digest
    end
  end
end
