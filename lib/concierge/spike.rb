module Concierge
  # THROWAWAY SPIKE — phase 10, step 0 (design §10.10).
  #
  # Everything under Concierge::Spike prototypes the (Agent × Subject) identity
  # model *before* seven tables are migrated, so that "does adding agent #2 read
  # well?" is answered cheaply. It migrates nothing: the agent dimension is faked
  # by folding the slug into +subject_type+ (see Spike::Scope#key), and per-run
  # provenance lives in memory (see Spike::Provenance).
  #
  # It is inert unless a host turns it on:
  #
  #   Concierge.configure do |c|
  #     c.multi_agent_spike = true
  #     c.agent(:csm)     { ... }
  #     c.agent(:billing) { ... }
  #   end
  #
  # Step 1 (#4982) deletes this directory and lands the real thing: an
  # +agent_slug+ column, Concierge::Scope, and a scope-keyed runtime.
  module Spike
    class << self
      # The flag. Off by default, so a host that never asks for multi-agent gets
      # byte-identical behaviour to today.
      def enabled?
        !!Concierge.config.multi_agent_spike
      end

      # Build a Scope for a declared agent over a host record id.
      def scope_for(agent_slug, subject)
        Scope.new(Concierge.config.agent(agent_slug), subject)
      end

      # Every enabled agent's Scope over one subject — what a sweep would iterate.
      def scopes_for(subject)
        Concierge.config.agents.select(&:enabled?).map { |a| Scope.new(a, subject) }
      end
    end
  end
end

require "concierge/spike/authority"
require "concierge/spike/agent"
require "concierge/spike/scope"
require "concierge/spike/memory_store"
require "concierge/spike/provenance"
require "concierge/spike/run"
