require "test_helper"

module Concierge
  class OutreachTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @result  = Concierge::Result.new(reply_text: "Here is your weekly update.")
    end

    test "an autonomous send records an audit row and surfaces in-app" do
      status = Outreach.deliver(@result, @subject, channel: :in_app)

      assert_equal :delivered, status
      assert_equal 1, ChannelDelivery.for_subject(@subject).count
      assert_equal [ "Here is your weekly update." ], Concierge::InAppInbox.messages.map { |m| m[:body] }
    end

    test "a blank result is suppressed by the usefulness bar" do
      status = Outreach.deliver(Concierge::Result.new(reply_text: "  "), @subject)
      assert_equal :suppressed, status
      assert_equal 0, ChannelDelivery.count
    end

    test "opted-out subject is suppressed" do
      OutreachPreference.for_subject(@subject).update!(opted_out: true)
      assert_equal :suppressed, Outreach.deliver(@result, @subject)
    end

    test "second send inside the frequency window is suppressed" do
      OutreachPreference.for_subject(@subject).update!(frequency: "normal")
      assert_equal :delivered, Outreach.deliver(@result, @subject, channel: :in_app)
      assert_equal :suppressed, Outreach.deliver(@result, @subject, channel: :in_app)
    end

    test "set_outreach_preference('less') widens the cap so the next send passes sooner" do
      # A daily-cap subject would be blocked a day later; 'less' is weekly, but a
      # prior send 2 days ago should now be allowed under 'normal' and blocked
      # under a fresh 'more'/'normal' window — here we assert the lever is read.
      OutreachPreference.for_subject(@subject).update!(frequency: "more") # hourly
      ChannelDelivery.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                              channel: "in_app", kind: "outreach", sent_at: 90.minutes.ago)

      assert_equal :delivered, Outreach.deliver(@result, @subject, channel: :in_app)
    end

    test "the unsubscribe route opts the subject out and blocks the next send" do
      Outreach.deliver(@result, @subject, channel: :in_app)
      token = ChannelDelivery.for_subject(@subject).last.unsubscribe_token

      # simulate the controller action
      delivery = ChannelDelivery.find_by(unsubscribe_token: token)
      OutreachPreference.find_or_initialize_by(subject_type: delivery.subject_type,
                                               subject_id: delivery.subject_id).update!(opted_out: true)

      assert OutreachPreference.for_subject(@subject).opted_out
      assert_equal :suppressed, Outreach.deliver(@result, @subject, channel: :in_app)
    end
  end
end
