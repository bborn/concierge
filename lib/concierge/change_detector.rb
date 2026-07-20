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
      last = Conversation.find_by_subject(@subject)&.last_snapshot_digest
      last.blank? || last != current_digest
    end

    def mark_reviewed!(at: nil)
      # Resolving the chat is what creates the conversation row when there isn't
      # one yet — there's nowhere else to record the digest.
      ChatResolver.call(@subject) unless Conversation.find_by_subject(@subject)
      Conversation.find_by_subject(@subject)
        &.update!(last_snapshot_digest: current_digest, last_reviewed_at: at || Time.current)
    end

    private

    def current_digest
      @current_digest ||= Snapshot.for(@subject).digest
    end
  end
end
