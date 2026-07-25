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
      end
    end
  end
end
