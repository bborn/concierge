# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# Dummy provider keys so RubyLLM's provider resolution succeeds when a Chat record
# is created. No real request is ever made — FakeChat intercepts every #ask.
ENV["OPENAI_API_KEY"]    ||= "test-openai-key"
ENV["ANTHROPIC_API_KEY"] ||= "test-anthropic-key"

require_relative "../test/dummy/config/environment"
# The dummy app owns the test schema: engine migrations are copied into it via
# `bin/rails concierge:install:migrations` (exactly as a real host does), so we
# point only at the dummy's migrate path — pointing at the engine's too would
# double-load every Concierge migration (DuplicateMigrationNameError).
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
require "rails/test_help"

require_relative "support/fake_chat"
require_relative "support/dummy_config"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

class ActiveSupport::TestCase
  # Each test starts from a clean configuration, and any run is served the chat
  # the test scripted via FakeChat — never a real LLM call.
  setup do
    Concierge.reset_config!
    Concierge::Test::FakeChat.reset!
    Concierge::Test.configure!
  end
end
