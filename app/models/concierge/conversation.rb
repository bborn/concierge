module Concierge
  # Maps a Subject to its persistent host Chat. Concierge reuses the host-owned
  # RubyLLM chat/messages/tool_calls tables rather than owning conversations, and
  # rather than mutating the host `chats` schema — this mapping table is the
  # least-invasive link (design §5 refinement; see plan A3).
  #
  # One conversation per (agent, subject), not per subject: without the agent
  # dimension two agents over one account share a persistent Chat, so every prior
  # turn of the CSM's thread lands in the billing agent's context window. That
  # contamination vector is why §10.1 keys this table by the pair.
  class Conversation < ApplicationRecord
    include AgentScoped

    validates :chat_id, presence: true
    validates :subject_id, uniqueness: { scope: [ :agent_slug, :subject_type ] }

    # The host Chat record this conversation points at. Resolved at call time so
    # the model class name stays configurable and no constant is needed at load.
    def chat_record
      Concierge.chat_model.find_by(id: chat_id)
    end
  end
end
