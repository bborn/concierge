module Concierge
  module Test
    # The canonical Concierge configuration for the dummy host app. Test setup
    # calls this after resetting config, so every test starts from the same
    # baseline (and can override afterward). Later phases extend it as new
    # boundaries land.
    def self.configure!
      Concierge.configure do |c|
        c.default_model = "claude-sonnet-4-5"
        c.chat_factory  = ->(model:, chat_record: nil) { FakeChat.current }

        c.account do
          subject_class Tenant
          grain :account
          attribute(:name) { |t| t.name }
          attribute(:plan) { |t| t.plan }
          scope(:users)    { |t| t.users }
        end

        c.playbook do
          product_brief "Acme helps teams publish changelogs."
          goals "Get each account to publish their first changelog and upgrade."
          account_types :brand, :creator

          engagement_signal(:has_paid_plan) { |s| %w[pro enterprise].include?(s[:plan]) }
          engagement_signal(:user_count)    { |s| s.scope_for(:users).count }
          engagement_signal(:days_since_active) do |s|
            last = s.to_model.last_active_at
            last ? ((Time.current - last) / 1.day).floor : nil
          end

          persona name: "Kit", voice: "warm, concise, never pushy"
        end

        c.capabilities do
          register Concierge::Tools::RecallTool,                access: :read
          register Concierge::Tools::RememberTool,             access: :write
          register Concierge::Tools::ForgetTool,              access: :write
          register Concierge::Tools::SetOutreachPreferenceTool, access: :write
          register Concierge::Tools::RoutineTool,             access: :write
        end

        c.channels           = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
        c.email_address_for  = ->(subject) { subject.to_model.users.first&.email }
        c.in_app_broadcaster = ->(subject, payload) { InAppInbox.record(subject, payload) }
        c.mailer_host        = "example.test"
      end
    end
  end

  # A tiny in-memory sink standing in for a real Turbo broadcast, so tests can
  # assert the in-app channel actively surfaced a message.
  class InAppInbox
    class << self
      def record(subject, payload)
        messages << { subject_id: subject.id, body: payload[:body] }
      end

      def messages
        @messages ||= []
      end

      def reset!
        @messages = []
      end
    end
  end
end
