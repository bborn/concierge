module Concierge
  # Maps a Subject to its persistent host Chat. Concierge reuses the host-owned
  # RubyLLM chat/messages/tool_calls tables rather than owning conversations, and
  # rather than mutating the host `chats` schema — this mapping table is the
  # least-invasive link (design §5 refinement; see plan A3).
  class Conversation < ApplicationRecord
    validates :chat_id, presence: true
    validates :subject_id, uniqueness: { scope: :subject_type }

    def self.for_subject(subject)
      find_by(subject_type: subject.grain.to_s, subject_id: subject.id.to_s)
    end

    # The host Chat record this conversation points at. Resolved at call time so
    # the model class name stays configurable and no constant is needed at load.
    def chat_record
      chat_model.find_by(id: chat_id)
    end

    private

    def chat_model
      Concierge.config.chat_model_name.constantize
    end
  end
end
