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
    # nil here means "Concierge has no opinion" — i.e. credentials are fine.
    # RubyLLM memoizes one registry per process (Models.instance) and picks its
    # source the first time anything asks: the host's `models` table when that
    # table has rows, the bundled JSON otherwise (models.rb#load_models). A Rails
    # host on acts_as_model — the recommended setup — normally has a `models`
    # table holding only the handful of models it has actually talked to, so
    # Models.find raises ModelNotFoundError for everything else.
    #
    # "Not in this host's table" is not "no such model", and treating it as one
    # made configured? answer true for almost every model on almost every Rails
    # host: credentials-are-fine for a host with no key at all, which silently
    # disables the offline degrade that ChatResolver#uncredentialed? exists to
    # provide. So a miss in the active registry falls back to the bundled JSON,
    # which is complete, offline, and the same data RubyLLM itself falls back to.
    # Only a model neither registry knows is genuinely unknown.
    def provider_for(model)
      return nil unless model

      lookup(RubyLLM.models, model) || lookup(bundled_registry, model)
    end

    # A registry may raise for a miss (ModelNotFoundError) or, if the host has
    # pointed it at something broken, for any other reason. Either way this
    # question has no answer from *this* registry; the caller tries the next one.
    def lookup(registry, model)
      registry.find(model)&.provider
    rescue StandardError
      nil
    end

    # RubyLLM's bundled model data, as its own registry instance — deliberately
    # not RubyLLM.models, so asking never disturbs the process-wide memoized
    # registry a host may have populated from its own table. Memoized against the
    # configured file so a host that repoints model_registry_file is re-read.
    def bundled_registry
      file = RubyLLM.config.model_registry_file
      return @bundled_registry if @bundled_registry && @bundled_registry_file == file

      @bundled_registry_file = file
      @bundled_registry = RubyLLM::Models.new(RubyLLM::Models.read_from_json(file))
    end

    private_class_method :lookup, :bundled_registry
  end
end
