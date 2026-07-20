require "test_helper"

class UnsubscribeTest < ActionDispatch::IntegrationTest
  include Concierge::Engine.routes.url_helpers

  setup do
    @tenant  = Tenant.create!(name: "Acme", plan: "pro")
    @tenant.users.create!(email: "a@acme.test")
    @subject = Concierge.config.account.build(@tenant)
    Concierge::Outreach.deliver(Concierge::Result.new(reply_text: "hi"), @subject, channel: :in_app)
    @token = Concierge::ChannelDelivery.for_subject(@subject).last.unsubscribe_token
  end

  test "a valid token opts the subject out" do
    get "/concierge/unsubscribe/#{@token}"

    assert_response :success
    assert Concierge::OutreachPreference.for(@subject).opted_out
  end

  test "an unknown token is rejected" do
    get "/concierge/unsubscribe/nope"
    assert_response :not_found
  end
end
