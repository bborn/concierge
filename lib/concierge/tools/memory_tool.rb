module Concierge
  module Tools
    # Save a durable note about the current account. Write-access.
    class RememberTool < Concierge::Capability::NativeTool
      description "Save a durable note about this account so you remember it in future conversations."
      param :body, desc: "The fact or note to remember."
      param :category, desc: "Optional label, e.g. 'preference' or 'billing'.", required: false

      def name
        "remember"
      end

      def perform(body:, category: nil)
        context_store.remember(scope, body: body, category: category, source: :agent)
        { ok: true }
      end
    end

    # Look up what's known about the current account. Read-access.
    class RecallTool < Concierge::Capability::NativeTool
      description "Look up durable notes about this account by keyword or category."
      param :query, desc: "Keyword to search note bodies for.", required: false
      param :category, desc: "Restrict to a category.", required: false

      def name
        "recall"
      end

      def perform(query: nil, category: nil)
        context_store.recall(scope, query: query, category: category).map(&:body)
      end
    end

    # Retire a note that's no longer true. Write-access (soft-delete only).
    class ForgetTool < Concierge::Capability::NativeTool
      description "Retire a durable note that is no longer accurate."
      param :id, desc: "The id of the note to forget."

      def name
        "forget"
      end

      def perform(id:)
        row = context_store.forget(scope, id)
        row ? { ok: true } : { error: "no note ##{id} for this account" }
      end
    end
  end
end
