module Concierge
  # Finds or creates the persistent host Chat for a Subject, going through the
  # Conversation mapping table. This is the one place account↔chat scoping lives,
  # so the run harness never has to reason about it.
  class ChatResolver
    def self.call(subject, model: nil)
      new(subject, model: model).call
    end

    def initialize(subject, model: nil)
      @subject = subject
      @model   = model || Concierge.config.default_model
    end

    def call
      conversation = Conversation.for_subject(@subject) || create_conversation
      conversation.chat_record
    end

    private

    def create_conversation
      # Create the Chat record without assigning a model — assigning one eagerly
      # resolves the provider (and demands its API key). The model is applied to
      # the RubyLLM chat at ask-time via the chat_factory instead.
      chat = chat_model.create!
      Conversation.create!(
        subject_type: @subject.grain.to_s,
        subject_id:   @subject.id.to_s,
        grain:        @subject.grain.to_s,
        chat_id:      chat.id
      )
    end

    def chat_model
      Concierge.config.chat_model_name.constantize
    end
  end
end
