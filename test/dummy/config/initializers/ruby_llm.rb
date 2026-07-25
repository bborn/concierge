RubyLLM.configure do |config|
  config.openai_api_key    = ENV.fetch("OPENAI_API_KEY", nil)

  # The dummy app is documented as working offline with no key (config/
  # initializers/concierge.rb swaps in a scripted chat when the key is absent),
  # but creating the *Chat record* still needs a configured provider: RubyLLM's
  # Models.resolve instantiates the provider — which calls ensure_configured! —
  # before it honours assume_model_exists. So a key-less boot raised
  # RubyLLM::ConfigurationError on the first run instead of answering offline.
  #
  # A placeholder keeps record creation working. Nothing can reach the network
  # on this path: with no real key the chat object is Dummy::ScriptedChat. This
  # mirrors what test/test_helper.rb already does for the same reason.
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"].presence || "offline-placeholder-key"

  # Use the association-based acts_as API (recommended)
  config.use_new_acts_as = true
end
