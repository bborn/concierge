module ApplicationCable
  # The socket the inbox pushes down. Two gates, because neither one is enough on
  # its own:
  #
  #   1. **Here** — the connection is rejected unless the cookie carries a signed-in
  #      user. Turbo's own channel would happily accept an anonymous socket and
  #      wait for a stream name; a demo whose "live" surface is reachable without
  #      signing in is not a demo of a per-account agent.
  #   2. **The stream name** — Turbo signs it, so the only stream a connection can
  #      subscribe to is one whose signed name a page already rendered for it.
  #      That is what keeps Acme off Globex's stream: `turbo_stream_from
  #      current_tenant` renders a signature Dana's browser has and Hank's does
  #      not, and the tenant is never taken from the request.
  #
  # HTTP has no session in ActionCable, so the cookie is read directly under the
  # app's own session key rather than hardcoding "_dummy_session" — a rename in
  # config would otherwise silently open the socket to everyone.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user_id

    def connect
      self.current_user_id = verified_user_id
    end

    private

    def verified_user_id
      id = session_cookie&.dig("user_id")
      user = User.find_by(id: id) if id
      reject_unauthorized_connection unless user

      user.id
    end

    def session_cookie
      cookies.encrypted[Rails.application.config.session_options[:key]]
    end
  end
end
