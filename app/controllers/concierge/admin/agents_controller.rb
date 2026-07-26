module Concierge
  module Admin
    # Every declared business function with its six slots, and the state each one
    # actually owns. This is the operator's answer to "what agents are running,
    # what may they touch, and what have they written?" — the screen the (Agent ×
    # Subject) identity model (design §10.1) makes necessary.
    class AgentsController < BaseController
      def index
        @agents      = Concierge.config.agents
        @memories    = Concierge::Memory.active.group(:agent_slug).count
        @routines    = Concierge::Routine.group(:agent_slug).count
        @deliveries  = Concierge::ChannelDelivery.group(:agent_slug).count
        @conversations = Concierge::Conversation.group(:agent_slug).count
        @rules         = Concierge::AgentRule.active.group(:agent_slug).count
        @proposals     = Concierge::AgentRule.proposed.group(:agent_slug).count
        @actions       = Concierge::AgentProposal.proposed.group(:agent_slug).count
        @takeovers     = Concierge::Handoff.active.group(:agent_slug).count
        @last_handbacks = last_handback_per_agent
      end

      private

      # Who last gave an account back to this agent. Recorded because releasing is
      # what re-enables its autonomous proactive sends, and read here because the
      # customer's page has no use for it: it answers "who is speaking for us right
      # now", and after a handback nobody is. This screen is the operator's.
      def last_handback_per_agent
        @agents.each_with_object({}) do |agent, handbacks|
          handbacks[agent.memory_namespace] =
            Concierge::Handoff.where(agent_slug: agent.memory_namespace, state: "released")
                              .order(released_at: :desc)
                              .first
        end
      end
    end
  end
end
