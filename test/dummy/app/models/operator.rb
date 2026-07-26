# Acme's support staff — the other side of the desk from a User.
#
# Not an ActiveRecord model, because there is nothing to store: this demo has no
# passwords for its customers either. What it *is* is a seat that is not a
# customer seat, which is the whole point. `config.authorize_operator` asks "are
# you staff", and a session holding a tenant user must not be able to answer yes:
# the engine's handoff endpoints seize a customer's thread and speak on it as
# Acme, and a customer doing that to themselves writes pinned human memory into
# their own agent's head.
#
# So the two doors write different session keys and `reset_session` between them.
# A real host would have a Staff record, an org-membership check, and a book of
# accounts each operator covers.
class Operator
  EMAIL = "support@acme.test".freeze

  SESSION_KEY = :operator_email

  class << self
    def sign_in(session)
      session[SESSION_KEY] = EMAIL
    end

    def signed_in?(session) = session[SESSION_KEY].present?

    def email(session) = session[SESSION_KEY]
  end
end
