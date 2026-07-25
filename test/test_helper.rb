# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# Only the Anthropic key is set — deliberately. The dummy config declares
# default_provider :anthropic, so creating a Chat never touches OpenAI. If this
# regressed (a Chat resolving RubyLLM's global default provider), the suite would
# fail with a missing-OpenAI-key error instead of silently passing on a crutch
# key. No real request is ever made — FakeChat intercepts every #ask.
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
    Concierge::InAppInbox.reset!
    Concierge::Spike::Provenance.reset!
  end
end
