require "test_helper"

# The socket the inbox pushes down.
#
# Turbo's signed stream name is the gate that keeps Acme off Globex's stream, and
# it is a good one — but it only ever runs *after* a connection has been
# accepted. A demo whose live surface holds open sockets for anyone who asks is
# not demonstrating a per-account agent, so the connection asks its own question
# first: are you signed in at all.
class HostCableConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  setup do
    @acme = Tenant.create!(name: "Acme Corp", plan: "pro")
    @dana = @acme.users.create!(email: "dana@acme.test")
  end

  test "a signed-in customer's socket is accepted and identified" do
    sign_in @dana

    connect

    assert_equal @dana.id, connection.current_user_id
  end

  test "an anonymous socket is refused" do
    assert_reject_connection { connect }
  end

  test "a session naming a user who no longer exists is refused" do
    sign_in @dana
    @dana.destroy

    assert_reject_connection { connect }
  end

  private

  # `cookies.encrypted[key] = value` in a connection test means something other
  # than it does in a request: the jar reads a Hash as cookie *options* and takes
  # its :value, so handing it the session hash directly stores nil and every test
  # here would pass for the wrong reason. The wrapper is the point of the helper.
  def sign_in(user)
    cookies.encrypted[session_key] = { value: { "user_id" => user.id } }
  end

  # Read from config rather than hardcoded, for the same reason the connection
  # does: a session-key rename must not quietly open the socket to everyone.
  def session_key = Rails.application.config.session_options[:key]
end
