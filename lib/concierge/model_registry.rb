module Concierge
  # Asks RubyLLM's model data what it knows about a model id — without a network
  # call, without a provider object, and without believing a partial answer.
  #
  # RubyLLM memoizes one registry per process (+Models.instance+) and picks its
  # source the first time anything asks: the configured +model_registry_store+
  # when it has rows, the registry file, then the bundled JSON
  # (models.rb#load_models). An +acts_as_chat+ host points that store at the
  # `ruby_llm_models` table, which normally holds only the handful of models the
  # host has actually talked to, so +Models.find+ raises +ModelNotFoundError+ for
  # everything else in existence.
  #
  # "Not in this host's table" is not "no such model", and reading it as one has
  # already cost this codebase one production defect (task 5014): the credentials
  # gate answered "credentials are fine" for a host with no key at all. So every
  # lookup here falls back to the bundled JSON, which is complete, offline, and the
  # same data RubyLLM itself falls back to. Only a model neither registry knows is
  # genuinely unknown.
  module ModelRegistry
    module_function

    # The +RubyLLM::Model+ for a model id, or nil when neither registry knows it.
    # Never raises: a miss is an answer, and every caller here has something
    # better to do with one than blow up.
    def find(model, provider = nil)
      return nil unless model

      lookup(RubyLLM.models, model, provider) || lookup(bundled, model, provider)
    end

    # RubyLLM's bundled model data, as its own registry instance — deliberately
    # not +RubyLLM.models+, so asking never disturbs the process-wide memoized
    # registry a host may have populated from its own table. Memoized against the
    # configured file so a host that repoints +model_registry_file+ is re-read.
    # +load_from_json+ falls back to the gem's bundled JSON when that file is
    # missing — which in ruby_llm 2.x is the usual case, since the default now
    # points at a per-user cache path that only a refresh writes.
    def bundled
      file = RubyLLM.config.model_registry_file
      return @bundled if @bundled && @bundled_file == file

      @bundled_file = file
      @bundled = RubyLLM::Models.new([]).load_from_json(file)
    end

    # A registry may raise for a miss (+ModelNotFoundError+) or, if the host has
    # pointed it at something broken, for any other reason. Either way this
    # question has no answer from *this* registry; the caller tries the next one.
    def lookup(registry, model, provider = nil)
      registry.find(model, provider: provider)
    rescue StandardError
      nil
    end

    private_class_method :lookup
  end
end
