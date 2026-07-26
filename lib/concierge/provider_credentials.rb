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
  module ProviderCredentials
    module_function

    # True when RubyLLM could build the provider behind (model, provider).
    #
    # An unknown provider or an unknown model answers true, deliberately:
    # Concierge has no opinion there, and RubyLLM's own error names the problem
    # far better than a silent degrade would.
    def configured?(model: nil, provider: nil)
      slug = provider || provider_for(model)
      return true unless slug

      provider_class = RubyLLM::Provider.providers[slug.to_sym]
      return true unless provider_class

      provider_class.configured?(RubyLLM.config)
    end

    # The provider a bare model id resolves to, from RubyLLM's local registry.
    # This is the same offline lookup acts_as_chat would do; it reads bundled
    # JSON and never reaches the network or a provider object.
    def provider_for(model)
      return nil unless model

      RubyLLM::Models.find(model)&.provider
    rescue StandardError
      nil
    end
  end
end
