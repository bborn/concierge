module Concierge
  module Admin
    class RoutinesController < BaseController
      def index
        @routines = Concierge::Routine.order(next_run_at: :asc).limit(200)
      end
    end
  end
end
