# Sign in as a seeded user. No passwords — this is a demo host, and the picker
# exists so you can switch accounts and watch what the agent knows change with
# you.
class SessionsController < ApplicationController
  skip_before_action :require_signed_in!, only: [ :new, :create ]

  def new
    @users = User.includes(:tenant).order(:tenant_id, :email)
  end

  def create
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
end
