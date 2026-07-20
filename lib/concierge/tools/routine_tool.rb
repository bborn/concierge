module Concierge
  module Tools
    # Lets the agent AND the customer (via chat) manage recurring routines
    # ("once a week send me this report"). All rows are scoped to the current
    # subject; the author is recorded so agent- and customer-created routines are
    # distinguishable.
    class RoutineTool < Concierge::Capability::NativeTool
      description "Create, update, list, or remove a recurring routine for this account. " \
                  "Use when you or the customer want something to happen on a schedule."
      param :action, desc: "create, update, destroy, or list."
      param :schedule, desc: "Cron or natural language, e.g. '0 9 * * 1' or 'every monday at 9am'.", required: false
      param :instruction, desc: "What the routine should do.", required: false
      param :channel, desc: "Optional channel: in_app or email.", required: false
      param :id, desc: "Routine id (for update/destroy).", required: false

      def name
        "manage_routine"
      end

      def perform(action:, schedule: nil, instruction: nil, channel: nil, id: nil, author: "customer")
        case action.to_s
        when "create"  then create(schedule, instruction, channel, author)
        when "update"  then update(id, schedule, instruction, channel)
        when "destroy" then destroy(id)
        when "list"    then list
        else { error: "unknown action #{action.inspect}" }
        end
      end

      private

      def create(schedule, instruction, channel, author)
        routine = scope.create!(schedule: schedule, instruction: instruction, channel: channel, author: author)
        { ok: true, id: routine.id, next_run_at: routine.next_run_at }
      end

      def update(id, schedule, instruction, channel)
        routine = scope.find_by(id: id)
        return { error: "no routine ##{id} for this account" } unless routine

        attrs = { schedule: schedule, instruction: instruction, channel: channel }.compact
        routine.update!(attrs)
        { ok: true, id: routine.id }
      end

      def destroy(id)
        routine = scope.find_by(id: id)
        return { error: "no routine ##{id} for this account" } unless routine

        routine.destroy!
        { ok: true }
      end

      def list
        scope.map { |r| { id: r.id, schedule: r.schedule, instruction: r.instruction, enabled: r.enabled } }
      end

      def scope
        Concierge::Routine.for_subject(subject)
      end
    end
  end
end
