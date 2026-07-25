module Concierge
  module Admin
    # The human gate, made a screen (design §10.2). A rule cannot go active
    # without a tap, and this is where the tap happens: proposal cards with their
    # provenance, their conflicts, and — when the active-rule cap is full — the
    # rules to consolidate before anything else can go live.
    #
    # Everything here goes through Concierge::Rules, so the same gate, the same
    # cap and the same conflict rules apply whether the actor is this screen, a
    # Slack button (§10.7), or a console.
    class RulesController < BaseController
      def index
        @proposed   = Concierge::AgentRule.proposed.order(created_at: :desc)
        @active     = Concierge::AgentRule.active.order(:agent_slug, :id)
        @retiring   = Concierge::AgentRule.active.retirement_proposed.order(:agent_slug, :id)
        @deprecated = Concierge::AgentRule.where(state: %w[deprecated rejected])
                                          .order(updated_at: :desc).limit(50)
        @cap        = Concierge::Rules.cap
      end

      def update
        rule = Concierge::AgentRule.find(params[:id])

        case params[:transition]
        when "activate"  then Concierge::Rules.activate!(rule, by: actor, acknowledge_conflicts: acknowledge?)
        when "reject"    then Concierge::Rules.reject!(rule, by: actor, reason: params[:reason])
        when "deprecate" then Concierge::Rules.deprecate!(rule, by: actor, reason: params[:reason])
        else
          return redirect_to admin_rules_path, alert: "unknown transition #{params[:transition].inspect}"
        end

        redirect_to admin_rules_path, notice: "Rule ##{rule.id} #{rule.reload.state}."
      rescue Concierge::Rules::CapReached, Concierge::Rules::ConflictError,
             Concierge::Rules::GateError => e
        # The refusals are the feature: they have to arrive as something an
        # operator can act on, not as a 500.
        redirect_to admin_rules_path, alert: e.message
      end

      private

      # Who is tapping. The engine cannot know the host's session shape, so it
      # asks: a host wires this to current_user through the same hook that
      # authorizes the admin. Absent that, the maker-checker gate refuses rather
      # than inventing an approver.
      def actor
        hook = Concierge.config.admin_actor
        (hook ? hook.call(self) : params[:by]).to_s
      end

      # Cast, don't just check presence. An unchecked Rails check_box posts its
      # hidden partner value "0", and "0".present? is true — which would wave every
      # conflict through from the browser while the gate looked fine from a console.
      def acknowledge?
        ActiveModel::Type::Boolean.new.cast(params[:acknowledge_conflicts]).present?
      end
    end
  end
end
