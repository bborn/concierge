RubyLLM.configure do |config|
  config.openai_api_key    = ENV.fetch("OPENAI_API_KEY", nil)

  # No placeholder key. A real host has none, and the engine now owns the
  # answer: Concierge::ChatResolver checks the provider's credentials before it
  # tries to persist a Chat, and runs without a persisted conversation when
  # there are none (see lib/concierge/provider_credentials.rb). The dummy app
  # exercises the same offline path a keyless host does — putting a fake key
  # here would have made this app the only one the documented path works in.
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)

  # Use the association-based acts_as API (recommended)
  config.use_new_acts_as = true
end
