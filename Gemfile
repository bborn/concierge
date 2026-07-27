source "https://rubygems.org"

# Specify your gem's dependencies in concierge.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

# For the dummy host only, and for exactly one thing: Turbo Streams over
# ActionCable, so the demo can show in-app delivery *actively surfacing* instead
# of waiting for a page load. It is not a dependency of the engine — the gemspec
# is unchanged, and Concierge ships no Turbo code. See Concierge::Channel::InApp.
gem "turbo-rails"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
