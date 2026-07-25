module Concierge
  # Finds or creates the persistent host Chat for an (Agent × Subject) scope,
  # going through the Conversation mapping table. This is the one place
  # agent↔account↔chat scoping lives, so the run harness never has to reason
  # about it. Two agents over one account hold two conversations — sharing one
  # would put every turn of the CSM's thread into the other agent's context.
  class ChatResolver
    def self.call(scope, model: nil)
      new(scope, model: model).call
    end

    def initialize(scope, model: nil)
      @scope = Scope.coerce(scope)
      @model = model || @scope.agent.model || Concierge.config.default_model
    end

    def call
      conversation = Conversation.find_by_scope(@scope) || create_conversation
      conversation.chat_record
    end

    private

    def create_conversation
      chat = Concierge.chat_model.new
      pin_model(chat)
      chat.save!
      Conversation.create!(**@scope.key, grain: @scope.subject.grain.to_s, chat_id: chat.id)
    end

    # Pin the Chat to Concierge's configured model. This matters because
    # RubyLLM's acts_as_chat resolves a model on save, falling back to its
    # *global* default (an OpenAI model) when none is set — which demands an
    # OpenAI key even for an Anthropic-only host. Assigning our model makes that
    # fallback never fire. With a configured default_provider we also assume the
    # model exists, so creation stays fully offline (no registry lookup).
    def pin_model(chat)
      return unless @model

      chat.model = @model
      if (provider = Concierge.config.default_provider)
        chat.provider = provider.to_s
        chat.assume_model_exists = true
      end
    end
  end
end
