module Concierge
  module Test
    # Reproduces the model registry a real Rails host actually has, for the
    # length of one block.
    #
    # test_helper pins the process-wide registry to the bundled JSON so the suite
    # is deterministic (see the note there). That is the right default, but it is
    # *not* what a host on acts_as_model runs: acts_as_model installs an
    # ActiveRecord registry source at class-definition time, and RubyLLM prefers
    # it the moment the `models` table has a row — so the host's live registry
    # holds only the handful of models it has actually talked to, and Models.find
    # raises ModelNotFoundError for every other model in existence.
    #
    # Pinning the JSON registry made that condition untestable as well as
    # non-flaky. This helper puts it back, deliberately and scoped, so the
    # behaviour under a partial registry is covered rather than papered over.
    module PartialModelRegistry
      # Runs the block against a registry backed by the host's `models` table,
      # holding exactly the models named in +holding+ and nothing else.
      #
      #   with_partial_model_registry("gpt-4.1-nano" => "openai") { ... }
      def with_partial_model_registry(holding = { "gpt-4.1-nano" => "openai" })
        holding.each do |model_id, provider|
          ::Model.create!(model_id: model_id, name: model_id, provider: provider)
        end

        saved = RubyLLM::Models.instance
        RubyLLM::Models.instance_variable_set(:@instance, nil)
        # Force the source decision now, so the block sees the DB-backed registry
        # rather than whatever the first lookup inside it happens to trigger.
        assert_operator RubyLLM::Models.all.size, :<=, holding.size,
                        "the registry did not fall back to the host's models table"
        yield
      ensure
        RubyLLM::Models.instance_variable_set(:@instance, saved) if saved
      end
    end
  end
end

ActiveSupport::TestCase.include Concierge::Test::PartialModelRegistry
