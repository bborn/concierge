require "test_helper"

module Concierge
  class OutreachMailerTest < ActionMailer::TestCase
    test "notify renders the body and a one-click unsubscribe header" do
      mail = Concierge::OutreachMailer.with(
        to: "a@acme.test",
        payload: { body: "Your weekly update is ready." },
        unsubscribe_token: "tok123"
      ).notify

      assert_equal [ "a@acme.test" ], mail.to
      assert_match "Your weekly update is ready.", mail.body.encoded
      assert_match "tok123", mail.body.encoded
      assert mail["List-Unsubscribe"].present?
      assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].value
    end
  end
end
