# Sign in as a seeded user. No passwords — this is a demo host, and the picker
# exists so you can switch accounts and watch what the agent knows change with
# you.
class SessionsController < ApplicationController
  skip_before_action :require_signed_in!, only: [ :new, :create ]

  def new
    @users = User.includes(:tenant).order(:tenant_id, :email)
  end

  def create
    return sign_in_operator if params[:operator].present?

    user = User.find_by(id: params[:user_id])
    return redirect_to(signin_path, alert: "Pick someone to sign in as.") unless user

    reset_session
    session[:user_id] = user.id
    redirect_to root_path, notice: "Signed in as #{user.label}."
  end

  def destroy
    reset_session
    redirect_to signin_path, notice: "Signed out."
  end

  private

  # The staff door. It sets no user_id, so an operator is signed in to nobody's
  # account: the product pages still want a customer and send them back here.
  # Their surfaces are the engine's — the admin console and the handoff
  # endpoints, which ask `config.authorize_operator` rather than
  # `config.authorize_subject`.
  def sign_in_operator
    reset_session
    Operator.sign_in(session)
    redirect_to concierge.admin_proposals_path, notice: "Signed in as #{Operator::EMAIL} (support)."
  end
end
