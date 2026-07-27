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
      OutreachPreference.for(@subject).update!(opted_out: true)
      assert_equal :suppressed, Outreach.deliver(@result, @subject)
    end

    test "second send inside the frequency window is suppressed" do
      OutreachPreference.for(@subject).update!(frequency: "normal")
      assert_equal :delivered, Outreach.deliver(@result, @subject, channel: :in_app)
      assert_equal :suppressed, Outreach.deliver(@result, @subject, channel: :in_app)
    end

    test "set_outreach_preference('less') widens the cap so the next send passes sooner" do
      # A daily-cap subject would be blocked a day later; 'less' is weekly, but a
      # prior send 2 days ago should now be allowed under 'normal' and blocked
      # under a fresh 'more'/'normal' window — here we assert the lever is read.
      OutreachPreference.for(@subject).update!(frequency: "more") # hourly
      ChannelDelivery.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                              channel: "in_app", kind: "outreach", sent_at: 90.minutes.ago)

      assert_equal :delivered, Outreach.deliver(@result, @subject, channel: :in_app)
    end

    # --- In-app has to actually surface (design §3.5) -------------------------

    test "in-app is not a channel at all without a broadcaster to surface through" do
      # Silently no-opping and auditing it as :delivered is the ledger asserting
      # the customer was reached over the one channel that had nowhere to reach
      # them. The router falls through to email instead.
      Concierge.configure { |c| c.in_app_broadcaster = nil }

      assert_equal :delivered, Outreach.deliver(@result, @subject, channel: :in_app)
      assert_equal "email", ChannelDelivery.for_subject(@subject).sole.channel
    end

    test "with no other channel either, nothing is sent and nothing is audited" do
      Concierge.configure do |c|
        c.in_app_broadcaster = nil
        c.channels = [ Concierge::Channel::InApp ]
      end

      assert_equal :no_channel, Outreach.deliver(@result, @subject, channel: :in_app)
      assert_equal 0, ChannelDelivery.count
    end

    # The delivery row is written before the send so the host's broadcaster can
    # read it — an in-app surface has to render *who* sent the message, and the
    # payload does not say. A send that then fails must not leave the row behind.
    test "the audit row for a failed send does not survive it" do
      Concierge.configure do |c|
        c.in_app_broadcaster = ->(_subject, _payload) { raise "the panel is on fire" }
      end

      assert_equal :failed, Outreach.deliver(@result, @subject, channel: :in_app)
      assert_equal 0, ChannelDelivery.count
    end

    test "the host's broadcaster can see the delivery row for the message it is surfacing" do
      seen = nil
      Concierge.configure do |c|
        c.in_app_broadcaster = lambda do |_subject, payload|
          seen = ChannelDelivery.find_by(unsubscribe_token: payload[:unsubscribe_token])
        end
      end

      Outreach.deliver(@result, @subject, channel: :in_app)

      assert seen, "the broadcaster was handed a message whose ledger entry did not exist yet"
      assert_equal "in_app", seen.channel
    end

    test "the unsubscribe route opts the subject out and blocks the next send" do
      Outreach.deliver(@result, @subject, channel: :in_app)
      token = ChannelDelivery.for_subject(@subject).last.unsubscribe_token

      # simulate the controller action
      delivery = ChannelDelivery.find_by(unsubscribe_token: token)
      OutreachPreference.find_or_initialize_by(subject_type: delivery.subject_type,
                                               subject_id: delivery.subject_id).update!(opted_out: true)

      assert OutreachPreference.for(@subject).opted_out
      assert_equal :suppressed, Outreach.deliver(@result, @subject, channel: :in_app)
    end
  end
end
