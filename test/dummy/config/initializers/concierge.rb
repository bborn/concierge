# Concierge configuration for the dummy host app.
#
# Runs under `bin/rails server`, so the Acme product surface, the engine's admin
# and the chat endpoint can all be exercised by hand. See db/seeds.rb for sample
# data, and lib/dummy/concierge_setup.rb for the configuration itself — it lives
# there so the host-surface integration tests can configure the engine exactly
# the way the running server does. A demo whose tests exercise a different config
# than the server is a demo that proves nothing.

Rails.application.config.to_prepare do
  Concierge.configure { |c| Dummy::ConciergeSetup.apply(c) }
end
