module Concierge
  module Tools
    # Lets the agent (and, via chat, the customer) manage recurring routines.
    # Phase 4 registers the seam; the real CRUD lands in Phase 7 once the
    # concierge_routines table exists. Kept inert but registered so the wiring
    # and grants are exercised early.
    class RoutineTool < Concierge::Capability::NativeTool
      description "Create, change, or remove a recurring routine (e.g. a weekly report)."
      param :action, desc: "create, update, or destroy.", required: false

      def name
        "manage_routine"
      end

      def execute(**)
        raise NotImplementedError, "routines land in Phase 7"
      end
    end
  end
end
