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
      conversation = Conversation.find_by_subject(@subject) || create_conversation
      conversation.chat_record
    end

    private

    def create_conversation
      # Create the Chat record without assigning a model — assigning one eagerly
      # resolves the provider (and demands its API key). The model is applied to
      # the RubyLLM chat at ask-time via the chat_factory instead.
      chat = Concierge.chat_model.create!
      Conversation.create!(**@subject.key, grain: @subject.grain.to_s, chat_id: chat.id)
    end
  end
end
