require "test_helper"

# The sign-in picker and the account switcher. Switching accounts and watching
# what the agent knows change with you is the demo, so the switcher is a surface
# with a test rather than a convenience.
class HostSignInTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  test "the picker lists every seeded user with their tenant and plan" do
    get signin_path

    assert_response :success
    assert_select ".picker__who", text: "Dana"
    assert_select ".picker__where", text: "Acme Corp · pro"
    assert_select ".picker__where", text: "Globex · enterprise"
  end

  test "an anonymous visitor is sent to the picker" do
    get root_path
    assert_redirected_to signin_path

    get account_path
    assert_redirected_to signin_path
  end

  test "signing in establishes the current user and tenant" do
    sign_in_as @dana

    assert_redirected_to root_path
    follow_redirect!
    assert_select ".whoami option[selected]", text: /Dana at Acme Corp · pro/
  end

  test "switching accounts changes whose product you are looking at" do
    @acme.changelog_entries.create!(title: "Acme only", status: "draft")
    @globex.changelog_entries.create!(title: "Globex only", status: "published",
                                      published_at: 1.day.ago)

    sign_in_as @dana
    get changelog_entries_path
    assert_select ".entry__title", text: "Acme only"
    assert_select ".entry__title", text: "Globex only", count: 0

    sign_in_as @hank
    get changelog_entries_path
    assert_select ".entry__title", text: "Globex only"
    assert_select ".entry__title", text: "Acme only", count: 0
  end

  test "the picker offers a staff door that is not one of the seats" do
    get signin_path

    assert_select ".picker__staff .picker__who", text: "Support"
    assert_select ".picker__staff .picker__where", text: /not a customer/
  end

  test "signing in as support establishes an operator and no customer" do
    sign_in_as_operator

    assert_redirected_to "/concierge/admin/proposals"
    get "/account"
    assert_redirected_to "/signin"
  end

  test "signing in as a customer clears any operator session, and back again" do
    # reset_session on both doors, so a browser can never hold both answers at
    # once — which is the only way "are you staff" and "is this account yours"
    # stay two questions rather than a union.
    sign_in_as_operator
    sign_in_as @dana

    post "/concierge/accounts/#{@acme.id}/handoff", params: { operator: "dana@acme.test" }
    assert_response :forbidden

    # A literal path: the request above went into the mounted engine, so the host
    # helper would come back with "/concierge" on the front of it.
    post "/signin", params: { operator: 1 }
    post "/concierge/accounts/#{@acme.id}/handoff", params: { operator: Operator::EMAIL }
    assert_response :created
  end

  test "signing out drops the session" do
    sign_in_as @dana
    delete signout_path

    assert_redirected_to signin_path
    get root_path
    assert_redirected_to signin_path
  end
end
