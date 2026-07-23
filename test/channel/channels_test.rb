require "test_helper"

module Concierge
  module Channel
    class ChannelsTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @tenant  = Tenant.create!(name: "Acme", plan: "pro")
        @user    = @tenant.users.create!(email: "a@acme.test")
        @subject = Concierge.config.account.build(@tenant)
      end

      test "a misconfigured channel returns configured? == false and no-ops without raising" do
        Concierge.config.email_address_for = nil
        channel = Email.new(subject: @subject)

        refute channel.configured?
        assert_nothing_raised { assert_equal false, channel.deliver(body: "hi") }
      end

      test "a channel whose send raises is swallowed by the base" do
        broken = Class.new(Base) do
          def name = :broken
          def perform_delivery(_payload) = raise("kaboom")
        end

        assert_nothing_raised do
          assert_equal false, broken.new(subject: @subject).deliver(body: "hi")
        end
      end

      test "in-app channel actively surfaces a message" do
        assert InApp.new(subject: @subject).deliver(body: "welcome!")
        assert_equal [ "welcome!" ], Concierge::InAppInbox.messages.map { |m| m[:body] }
      end

      test "email channel delivers through deliver_later without a serialization error" do
        # deliver_later serializes every mailer param through ActiveJob. Passing
        # the Concierge::Subject raised ActiveJob::SerializationError, which the
        # base swallowed — so email silently never sent. Drive the real async
        # path (inline adapter) and assert a mail actually lands.
        perform_enqueued_jobs do
          assert Email.new(subject: @subject).deliver(body: "your weekly update", unsubscribe_token: "tok")
        end

        mail = ActionMailer::Base.deliveries.last
        assert mail, "expected a mail to be delivered"
        assert_equal [ "a@acme.test" ], mail.to
        assert_match "your weekly update", mail.body.encoded
      end

      test "router picks the first configured + available channel" do
        channel = Router.new.pick(@subject)
        assert_equal :in_app, channel.name
      end

      test "router honors a preferred channel" do
        channel = Router.new.pick(@subject, preferred: :email)
        assert_equal :email, channel.name
      end

      test "router honors a String preferred channel (routine.channel is a String)" do
        # Routine#channel is a String column; Channel#name is a Symbol. The
        # router must match across the two or a routine's requested channel is
        # silently ignored and delivery falls back to the default channel.
        channel = Router.new.pick(@subject, preferred: "email")
        assert_equal :email, channel.name
      end

      test "router returns nil when nothing can reach the subject" do
        Concierge.config.email_address_for = nil
        Concierge.config.channels = [ Email ] # in-app removed, email unconfigured
        assert_nil Router.new.pick(@subject)
      end
    end
  end
end
