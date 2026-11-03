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
    # was handed an id: +ChatMethods#model=+ with a +RubyLLM::ActiveRecord::Model+
    # clears the pending id, and +resolve_model+ then has nothing to do (ruby_llm
    # 2.1.1, active_record/chat_methods.rb). Handing it an id is what reaches
    # +Models.resolve+, which instantiates the provider — ensure_configured!,
    # raise — and so a keyless host would get no host Chat at all, and with it no
    # persisted conversation: every transcript surface in the product would read
    # empty offline (task 4997).
    #
    # The way out was never a flag, it was ownership. Concierge resolves the model
    # itself — the same registry data RubyLLM would have read, none of the provider
    # object it would have built — writes the `ruby_llm_models` row, and assigns
    # the association. The before_save then has nothing left to do, and creating
    # the Chat needs no credentials. Online and offline become one path, which is
    # the point: the demo exercises the code the engine actually runs. It also
    # keeps RubyLLM's own fallback from running — on an empty registry table that
    # fallback copies the *entire* model catalogue into the host's database just
    # to pin one row.
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

    # The `ruby_llm_models` row for this model, created if the host has never seen
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

    # ruby_llm 2.x retired the host-owned +acts_as_model+ class: an acts_as_chat
    # chat always belongs_to the engine-owned +RubyLLM::ActiveRecord::Model+
    # (table +ruby_llm_models+). Read it off the association rather than naming
    # it, so a host chat class that is not acts_as_chat simply has no registry.
    def host_model_class
      chat_class = Concierge.chat_model
      return unless chat_class.include?(RubyLLM::ActiveRecord::ChatMethods)

      chat_class.reflect_on_association(:model)&.klass
    rescue NameError
      nil
    end

    # Find-then-create rather than find_or_create_by! so a second process losing
    # the race re-reads the row the winner wrote instead of failing a run over the
    # uniqueness the registry declares on (model_id, provider).
    def find_or_create_model(registry, info)
      registry.find_by(model_id: info.id, provider: info.provider) ||
        registry.from_llm(info).tap(&:save!)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      registry.find_by!(model_id: info.id, provider: info.provider)
    end

    # A port of RubyLLM::Models.resolve with the one line removed that needs
    # credentials — +provider_class.new(config)+. Same inputs, no provider object:
    #
    #   * a host that names its provider assumes the model exists, which is what
    #     the default chat factory tells RubyLLM to do too, and gets the assumed
    #     default — so the pinned model id is exactly the id the host configured,
    #     as it always has been. (2.x +resolve+ now consults the registry first
    #     even when assuming, which would pin an alias's dated id instead; the
    #     runtime chat still resolves that alias itself, so pinning the
    #     configured id keeps existing conversations' rows stable for nothing);
    #   * a *local* provider (ollama and friends), or one that declares
    #     +assume_models_exist?+, consults the registry first, exactly as resolve
    #     does, because there the registry is authoritative;
    #   * a host that names no provider gets the registry's own answer, alias
    #     resolution and all — resolve's other branch;
    #   * ...and if that host's registry is partial, ModelRegistry falls back to
    #     RubyLLM's bundled data rather than reading a miss as "no such model".
    #     Not a nicety: without it a keyless host whose registry table holds a few
    #     rows would raise ModelNotFoundError here for every model it has never
    #     held, which is the shape of the defect task 5014 fixed one layer up.
    def model_info
      provider = configured_provider
      return registry_info_for(@model) unless provider

      provider_class = RubyLLM::Provider.providers[provider.to_sym] || raise_unknown_provider(provider)

      found = ModelRegistry.find(@model, provider) if registry_authoritative?(provider_class)
      found || RubyLLM::Model.default(@model, provider_class.slug)
    end

    def registry_authoritative?(provider_class)
      provider_class.local? ||
        (provider_class.respond_to?(:assume_models_exist?) && provider_class.assume_models_exist?)
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
