module Concierge
  # Answers "does this provider actually have credentials?" *without*
  # instantiating it — because instantiating it is precisely what blows up.
  #
  # RubyLLM::Provider#initialize calls ensure_configured!, and Models.resolve
  # builds the provider before it honours +assume_exists+ (ruby_llm 1.16.0,
  # models.rb:154-183). Both branches of resolve instantiate. So there is no way
  # to talk RubyLLM into resolving a model on an uncredentialed provider — not
  # with assume_model_exists, and not by leaving the provider unset either.
  #
  # RubyLLM does expose the same check one level up, as a class method that reads
  # the config without building a connection. That is what we ask, so Concierge
  # can decide what to do about an offline host instead of being told by a raise
  # from deep inside a before_save.
  #
  # Concierge no longer *withholds* the host Chat over this answer — ChatResolver
  # resolves the model record itself and never lets the before_save run, so a
  # keyless host gets a persisted conversation like any other. What is left is the
  # thing worth saying out loud: the turn on that conversation will only reach a
  # provider once the key is set.
  module ProviderCredentials
    module_function

    # True when RubyLLM could build the provider behind (model, provider).
    #
    # An unknown provider or an unknown model answers true, deliberately:
    # Concierge has no opinion there, and RubyLLM's own error names the problem
    # far better than a silent degrade would. "Unknown" means unknown to
    # RubyLLM's own model data — not merely absent from this host's registry.
    # See +provider_for+ for why that distinction is the whole ballgame.
    def configured?(model: nil, provider: nil)
      slug = provider || provider_for(model)
      return true unless slug

      provider_class = RubyLLM::Provider.providers[slug.to_sym]
      return true unless provider_class

      provider_class.configured?(RubyLLM.config)
    end

    # The provider a bare model id resolves to. Reads RubyLLM's local model data
    # only: no network, no provider object.
    #
    # Asked of the *active* registry alone this answers nil far too often, and a
    # nil here means "Concierge has no opinion" — i.e. credentials are fine. So
    # the lookup goes through ModelRegistry, which falls back to RubyLLM's bundled
    # data when the host's own `models` table has never heard of the model. See
    # the note there: reading "not in this host's table" as "no such model" is
    # what made this method answer credentials-are-fine for a host with no key.
    def provider_for(model)
      ModelRegistry.find(model)&.provider
    end
  end
end
