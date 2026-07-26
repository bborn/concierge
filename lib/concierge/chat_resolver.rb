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
      conversation = Conversation.find_by_scope(@scope)
      return conversation.chat_record if conversation
      return if uncredentialed?

      create_conversation.chat_record
    end

    private

    # Creating the host Chat *record* is what needs credentials, which is not
    # obvious and cost the offline path a whole phase: acts_as_chat resolves a
    # model in a before_save, and Models.resolve instantiates the provider —
    # ensure_configured!, raise — *before* it honours assume_exists. So
    # pin_model's assumption never gets a chance to help, and leaving the
    # provider unset only routes to the other branch of resolve, which
    # instantiates too. There is no combination of flags that makes it work.
    #
    # So Concierge answers for itself: no credentials, no persisted
    # conversation. The run proceeds against whatever chat the host's
    # chat_factory returns — which is the documented offline path, where the
    # host has scripted a double and never intended to reach a provider at all.
    #
    # This degrades; it does not pretend. A host that has *not* supplied an
    # offline factory gets the default one, which builds a real RubyLLM.chat and
    # raises the same ConfigurationError — surfaced by Run as a failed Result.
    # Losing persistence is loud in the log, and losing the model is loud in the
    # Result. Neither is a green run against a provider that isn't there.
    def uncredentialed?
      return false if ProviderCredentials.configured?(model: @model, provider: configured_provider)

      Concierge.logger&.warn(
        "[concierge] no credentials configured for #{configured_provider || @model.inspect}; " \
        "running without a persisted conversation. Chat history will not be saved until the " \
        "provider's API key is set."
      )
      true
    end

    def configured_provider
      Concierge.config.default_provider
    end

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
      if (provider = configured_provider)
        chat.provider = provider.to_s
        chat.assume_model_exists = true
      end
    end
  end
end
