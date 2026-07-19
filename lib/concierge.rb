require "ruby_llm"

require "concierge/version"
require "concierge/configuration"
require "concierge/subject"
require "concierge/account_adapter"
require "concierge/playbook"
require "concierge/snapshot"
require "concierge/engine"

# Concierge — a per-account AI customer success manager for Rails, built on RubyLLM.
#
# The host app mounts the engine and describes three things through the config DSL:
#   * what an account is (AccountAdapter, added in later phases)
#   * what the app does and what "engaged" means (Playbook)
#   * what the agent is allowed to touch (Capability registry + Channels)
#
# Concierge supplies the runtime, durable memory, channels, and scheduling.
module Concierge
  # Base error class for everything the gem raises on purpose.
  class Error < StandardError; end

  # Raised when a run needs a persona the host never configured (see Playbook).
  class PersonaNotConfigured < Error; end

  class << self
    # Yields the singleton Configuration so the host can set it up:
    #
    #   Concierge.configure do |config|
    #     config.default_model = "claude-sonnet-4-5"
    #   end
    def configure
      yield config
      config
    end

    # The memoized Configuration for this process.
    def config
      @config ||= Configuration.new
    end

    # Drops the memoized configuration. Primarily a test seam — the suite calls
    # this in setup so each example starts from a clean slate.
    def reset_config!
      @config = nil
    end
  end
end
