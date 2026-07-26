module Concierge
  # Asks RubyLLM's model data what it knows about a model id — without a network
  # call, without a provider object, and without believing a partial answer.
  #
  # RubyLLM memoizes one registry per process (+Models.instance+) and picks its
  # source the first time anything asks: the host's `models` table when that table
  # has rows, the bundled JSON otherwise (models.rb#load_models). A Rails host on
  # +acts_as_model+ — the recommended setup — normally has a `models` table holding
  # only the handful of models it has actually talked to, so +Models.find+ raises
  # +ModelNotFoundError+ for everything else in existence.
  #
  # "Not in this host's table" is not "no such model", and reading it as one has
  # already cost this codebase one production defect (task 5014): the credentials
  # gate answered "credentials are fine" for a host with no key at all. So every
  # lookup here falls back to the bundled JSON, which is complete, offline, and the
  # same data RubyLLM itself falls back to. Only a model neither registry knows is
  # genuinely unknown.
  module ModelRegistry
    module_function

    # The +Model::Info+ for a model id, or nil when neither registry knows it.
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
    def bundled
      file = RubyLLM.config.model_registry_file
      return @bundled if @bundled && @bundled_file == file

      @bundled_file = file
      @bundled = RubyLLM::Models.new(RubyLLM::Models.read_from_json(file))
    end

    # A registry may raise for a miss (+ModelNotFoundError+) or, if the host has
    # pointed it at something broken, for any other reason. Either way this
    # question has no answer from *this* registry; the caller tries the next one.
    def lookup(registry, model, provider = nil)
      provider ? registry.find(model, provider) : registry.find(model)
    rescue StandardError
      nil
    end

    private_class_method :lookup
  end
end
