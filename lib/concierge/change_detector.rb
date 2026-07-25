module Concierge
  # Gates proactive runs on "something changed since we last looked," so idle
  # accounts don't burn budget (design §4.3). Compares the current account
  # Snapshot digest to the one stored when this agent last reviewed the account.
  #
  # Per (agent, subject), because the digest is computed from the agent's own
  # engagement signals: two agents legitimately see two different pictures of one
  # account, and one agent's review must not mark the other's as done.
  class ChangeDetector
    def self.changed?(scope)
      new(scope).changed?
    end

    def self.mark_reviewed!(scope, at: nil)
      new(scope).mark_reviewed!(at: at)
    end

    def initialize(scope)
      @scope = Scope.coerce(scope)
    end

    def changed?
      last = Conversation.find_by_scope(@scope)&.last_snapshot_digest
      last.blank? || last != current_digest
    end

    def mark_reviewed!(at: nil)
      # Resolving the chat is what creates the conversation row when there isn't
      # one yet — there's nowhere else to record the digest.
      ChatResolver.call(@scope) unless Conversation.find_by_scope(@scope)
      Conversation.find_by_scope(@scope)
        &.update!(last_snapshot_digest: current_digest, last_reviewed_at: at || Time.current)
    end

    private

    def current_digest
      @current_digest ||= Snapshot.for(@scope.subject, playbook: @scope.agent.playbook).digest
    end
  end
end
