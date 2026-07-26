module Concierge
  module Test
    # Reproduces "this host has no API key" *precisely*, for the length of one
    # block, without touching ENV.
    #
    # test_helper sets ANTHROPIC_API_KEY on purpose: it is the signal that a Chat
    # never falls back to RubyLLM's global default provider (an OpenAI model),
    # and unsetting it suite-wide would destroy that signal. But the env var is
    # only ever read once, at boot, to populate RubyLLM.config.anthropic_api_key
    # — and it is the *config* the provider reads when it decides whether it is
    # configured. Clearing the config value is therefore the real condition, not
    # a stand-in for it, and it leaves every other test's signal intact.
    module OfflineProvider
      # Runs the block with the credentials for +provider+ cleared, restoring
      # them afterwards even if the block raises.
      def without_provider_credentials(provider = :anthropic)
        requirements = RubyLLM::Provider.providers.fetch(provider.to_sym).configuration_requirements
        saved = requirements.to_h { |key| [ key, RubyLLM.config.send(key) ] }

        saved.each_key { |key| RubyLLM.config.send(:"#{key}=", nil) }
        yield
      ensure
        saved&.each { |key, value| RubyLLM.config.send(:"#{key}=", value) }
      end
    end
  end
end

ActiveSupport::TestCase.include Concierge::Test::OfflineProvider
