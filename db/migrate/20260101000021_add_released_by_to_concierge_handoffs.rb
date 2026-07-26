# Who handed the thread back. `operator` and `seized_at` recorded who took a
# customer's thread over; `released_at` recorded only that somebody gave it back.
#
# Releasing is the act that re-enables autonomous proactive outbound for that
# (agent, subject) — Concierge::Run suppresses proactive runs only while a
# handoff is active — so it is at least as consequential as seizing, and on a
# real support desk it is routinely a different person.
#
# Nullable and not backfilled: rows released before this migration were released
# by somebody the engine never asked about, and inventing a name for them would
# be worse than a blank. New handbacks are refused without one (see
# Concierge::Handoff).
class AddReleasedByToConciergeHandoffs < ActiveRecord::Migration[7.1]
  def change
    add_column :concierge_handoffs, :released_by, :string
  end
end
