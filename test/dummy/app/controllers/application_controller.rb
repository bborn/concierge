class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :require_signed_in!

  helper_method :current_user, :current_tenant, :signed_in?, :inbox,
                :csm_persona, :billing_persona, :handoff, :handoff_active?

  private

  # No passwords: the picker exists so you can switch accounts and watch the
  # agent's knowledge change, which is the whole demo.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = User.includes(:tenant).find_by(id: session[:user_id])
  end

  def signed_in? = current_user.present?

  def current_tenant = current_user&.tenant

  def require_signed_in!
    redirect_to signin_path unless signed_in?
  end

  # Every Concierge read on a host page goes through one of these two, so the
  # narrowing is (agent, this account) at the call site and not something a
  # controller could forget. A host surface must never become a way to read
  # another account's state.
  def current_subject
    @current_subject ||= Concierge.config.account.find_subject(current_tenant.id)
  end

  def concierge_scope(slug = :csm)
    agent = Concierge.config.agent(slug)
    raise ActionController::RoutingError, "no #{slug} agent configured" unless agent

    Concierge::Scope.new(agent, current_subject)
  end

  def inbox
    @inbox ||= Inbox.new(current_tenant)
  end

  def handoff
    return @handoff if defined?(@handoff)

    @handoff = Concierge::Handoff.active_for(concierge_scope(:csm))
  end

  def handoff_active? = handoff.present?

  def csm_persona     = persona_for(:csm)
  def billing_persona = persona_for(:billing)

  # The agent is shown to the customer by the name the host gave it, never as
  # "Concierge" — the engine is plumbing, Kit is who they are talking to.
  def persona_for(slug)
    Concierge.config.agent(slug)&.playbook&.persona
  end

  # The "Kit, take a look" control is a demo affordance, not a product feature.
  def require_local!
    head :forbidden unless Rails.env.local?
  end
end
