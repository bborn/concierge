require "test_helper"

module Concierge
  class GovernanceTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @gov = Governance.new
    end

    test "allows a first send" do
      assert @gov.allow?(@subject, kind: "outreach")
    end

    test "opt-out suppresses delivery" do
      OutreachPreference.for(@subject).update!(opted_out: true)
      refute @gov.allow?(@subject)
    end

    test "frequency cap blocks a second send inside the window" do
      OutreachPreference.for(@subject).update!(frequency: "normal") # daily
      @gov.record!(@subject, channel: :email, kind: "outreach")

      refute @gov.allow?(@subject, kind: "outreach")
    end

    test "frequency cap clears once the window passes" do
      OutreachPreference.for(@subject).update!(frequency: "normal")
      ChannelDelivery.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                              channel: "email", kind: "outreach", sent_at: 2.days.ago)

      assert @gov.allow?(@subject, kind: "outreach")
    end

    test "frequency off blocks everything" do
      OutreachPreference.for(@subject).update!(frequency: "off")
      refute @gov.allow?(@subject)
    end

    test "quiet hours suppress delivery" do
      OutreachPreference.for(@subject).update!(quiet_hours_start: 0, quiet_hours_end: 24)
      refute @gov.allow?(@subject)
    end

    test "usefulness bar rejects an empty message" do
      refute @gov.usefulness_ok?(body: "   ")
      assert @gov.usefulness_ok?(body: "here is your weekly report")
    end
  end
end
