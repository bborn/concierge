class User < ApplicationRecord
  belongs_to :tenant

  # "Dana" out of "dana@acme.test" — there is no password and no profile here,
  # because the sign-in picker exists to switch accounts, not to authenticate.
  def display_name
    email.to_s.split("@").first.to_s.capitalize.presence || email.to_s
  end

  def label
    "#{display_name} at #{tenant.name} · #{tenant.plan}"
  end
end
