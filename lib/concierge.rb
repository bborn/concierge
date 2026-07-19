require "ruby_llm"

require "concierge/version"
require "concierge/configuration"
require "concierge/subject"
require "concierge/account_adapter"
require "concierge/playbook"
require "concierge/snapshot"
require "concierge/context_store"
require "concierge/capability/registry"
require "concierge/capability/native_tool"
require "concierge/capability/mcp_adapter"
require "concierge/tools/memory_tool"
require "concierge/tools/set_outreach_preference_tool"
require "concierge/tools/routine_tool"
require "concierge/result"
require "concierge/chat_resolver"
require "concierge/run"
require "concierge/channel/base"
require "concierge/channel/in_app"
require "concierge/channel/email"
require "concierge/channel/router"
require "concierge/governance"
require "concierge/outreach"
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

    # Where the gem logs. Host-overridable via config.logger; falls back to the
    # Rails logger when mounted.
    def logger
      config.logger || (defined?(Rails) ? Rails.logger : nil)
    end
  end
end
