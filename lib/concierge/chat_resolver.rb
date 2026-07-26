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

      warn_if_uncredentialed
      create_conversation.chat_record
    end

    private

    def create_conversation
      chat = Concierge.chat_model.new
      pin_model(chat)
      chat.save!
      Conversation.create!(**@scope.key, grain: @scope.subject.grain.to_s, chat_id: chat.id)
    end

    # Pin the Chat to Concierge's configured model — as a **record**, never as a
    # name. Which of the two it is turns out to be the whole difference between a
    # host that keeps a transcript and one that keeps nothing.
    #
    # acts_as_chat resolves a model in a before_save, and it only does so when it
    # was handed a *string*: +resolve_model_from_strings+ returns immediately when
    # +model_association+ is already set and no string is pending (ruby_llm 1.16.0,
    # chat_methods.rb:46-49). Handing it a string is what reached +Models.resolve+,
    # which instantiates the provider — ensure_configured!, raise — *before* it
    # honours assume_exists. There is genuinely no combination of flags that
    # survives that; task 4997 checked each one. So for a phase a keyless host got
    # no host Chat at all, and with it no persisted conversation: every transcript
    # surface in the product read empty offline, and a change to what the engine
    # persists could not be demonstrated by driving the running demo at all.
    #
    # The way out was never a flag, it was ownership. Concierge resolves the model
    # itself — the same registry data RubyLLM would have read, none of the provider
    # object it would have built — writes the host's `models` row, and assigns the
    # association. The before_save then has nothing left to do, and creating the
    # Chat needs no credentials. Online and offline become one path, which is the
    # point: the demo now exercises the code the engine actually runs.
    #
    # Losing the *model* is still loud. A host with no key and no offline
    # chat_factory gets the provider's own ConfigurationError back as a failed
    # Result the moment the run tries to talk (Run rescues it) — it simply gets a
    # conversation to have failed on, and a thread that continues where it left off
    # once the key arrives.
    def pin_model(chat)
      record = model_record
      return unless record

      chat.model = record
    end

    # The host's `models` row for this model, created if the host has never seen
    # it. This is exactly the row acts_as_chat's before_save would have written; we
    # write it one step earlier, from data that needs no provider.
    #
    # nil when there is nothing to pin: no model configured, or a host chat class
    # that keeps no model registry at all (a plain AR class rather than
    # acts_as_chat). Such a host never had a model association to set.
    def model_record
      return unless @model

      registry = host_model_class
      return unless registry

      find_or_create_model(registry, model_info)
    end

    def host_model_class
      chat_class = Concierge.chat_model
      return unless chat_class.respond_to?(:model_class)

      chat_class.model_class.constantize
    rescue NameError
      nil
    end

    # Find-then-create rather than find_or_create_by! so a second process losing
    # the race re-reads the row the winner wrote instead of failing a run over the
    # uniqueness index acts_as_model declares on (model_id, provider).
    def find_or_create_model(registry, info)
      registry.find_by(model_id: info.id, provider: info.provider) ||
        registry.from_llm(info).tap(&:save!)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      registry.find_by!(model_id: info.id, provider: info.provider)
    end

    # A faithful port of RubyLLM::Models.resolve (1.16.0, models.rb:154-183) with
    # the one line removed that needs credentials — +provider_class.new(config)+.
    # Same inputs, same answers, no provider object:
    #
    #   * a host that names its provider assumes the model exists, which is what
    #     the old pin_model already told RubyLLM to do, and gets the assumed
    #     default — so the pinned model id does not change under this rewrite;
    #   * a *local* provider (ollama and friends) consults the registry first,
    #     exactly as resolve does, because there the registry is authoritative;
    #   * a host that names no provider gets the registry's own answer, alias
    #     resolution and all — resolve's other branch;
    #   * ...and if that host's registry is partial, ModelRegistry falls back to
    #     RubyLLM's bundled data rather than reading a miss as "no such model".
    #     Not a nicety: without it a keyless host on acts_as_model would raise
    #     ModelNotFoundError here for every model its own table has never held,
    #     which is the shape of the defect task 5014 fixed one layer up.
    def model_info
      provider = configured_provider
      return registry_info_for(@model) unless provider

      provider_class = RubyLLM::Provider.providers[provider.to_sym] || raise_unknown_provider(provider)

      found = ModelRegistry.find(@model, provider) if provider_class.local?
      found || RubyLLM::Model::Info.default(@model, provider_class.slug)
    end

    # Word for word what Models.resolve says about a provider it does not know, so
    # a typo'd default_provider reads the same however it is found out. Run rescues
    # RubyLLM::Error, so this reaches the host as a failed Result, not a raise.
    def raise_unknown_provider(provider)
      raise RubyLLM::Error, "Unknown provider: #{provider.inspect}. " \
                            "Available providers: #{RubyLLM::Provider.providers.keys.join(', ')}"
    end

    # With no provider named there is nothing to assume, so a model neither
    # registry knows is a real error — and RubyLLM's own is the best one going, it
    # names the model and says how to refresh the registry.
    def registry_info_for(model)
      ModelRegistry.find(model) || RubyLLM.models.find(model)
    end

    # Persistence no longer turns on this answer, but the host still deserves to be
    # told, when the conversation is opened, that nothing on it will reach a
    # provider yet. A host on the documented offline path (a scripted chat_factory)
    # reads this as confirmation; a host that has *not* supplied one is about to
    # get RubyLLM's ConfigurationError back as a failed Result, and this is the
    # line that explains why.
    def warn_if_uncredentialed
      return if ProviderCredentials.configured?(model: @model, provider: configured_provider)

      Concierge.logger&.warn(
        "[concierge] no credentials configured for #{configured_provider || @model.inspect}; " \
        "opening a persisted conversation anyway, but no turn on it will reach a provider " \
        "until the provider's API key is set."
      )
    end

    def configured_provider
      Concierge.config.default_provider
    end
  end
end
