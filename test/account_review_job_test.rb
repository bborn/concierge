require "test_helper"

module Concierge
  class AccountReviewJobTest < ActiveJob::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "runs a proactive review, spends budget, delivers, and marks reviewed" do
      Concierge.config.budget = { per_tenant: 1_000_000, global: 1_000_000 }
      Concierge::Test::FakeChat.script(reply: "Here is your weekly update.")

      Concierge::AccountReviewJob.perform_now(@tenant.id, instruction: "weekly review", channel: :in_app)

      assert_equal 1, ChannelDelivery.for_subject(@subject).count
      assert_equal [ "Here is your weekly update." ], Concierge::InAppInbox.messages.map { |m| m[:body] }
      assert Concierge::Budget.new.spent_for(@subject).positive?
      assert Conversation.find_by_subject(@subject).last_reviewed_at.present?
    end
  end
end
