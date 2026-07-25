module Concierge
  module Test
    # The canonical Concierge configuration for the dummy host app. Test setup
    # calls this after resetting config, so every test starts from the same
    # baseline (and can override afterward). Later phases extend it as new
    # boundaries land.
    def self.configure!
      Concierge.configure do |c|
        c.default_model    = "claude-sonnet-4-5"
        c.default_provider = :anthropic
        c.chat_factory     = ->(model:, chat_record: nil) { FakeChat.current }

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

        c.weekly_review_enabled     = true
        c.weekly_review_instruction = "Review this account and reach out if something is worth their attention."
        c.priority = ->(subject) { subject[:plan] == "enterprise" ? 100 : 1 }
      end
    end

    # The pluralized form of the same host: two business functions over the same
    # Tenants. Deliberately NOT part of the baseline above — every other test
    # keeps running against the *single-agent* configuration, which is how we
    # know the §10.9 back-compat path (top-level blocks fold into an implicit
    # :csm agent) is exercised on every run rather than assumed. Mirrors
    # test/dummy/config/initializers/concierge.rb.
    def self.configure_agents!
      Concierge.configure do |c|
        c.agent :csm do
          persona name: "Kit", voice: "warm, concise, never pushy"

          playbook do
            product_brief "Acme helps teams publish changelogs."
            goals "Get each account to publish their first changelog and upgrade."
            engagement_signal(:has_paid_plan) { |s| %w[pro enterprise].include?(s[:plan]) }
            engagement_signal(:user_count)    { |s| s.scope_for(:users).count }
          end

          capabilities do
            register Concierge::Tools::RecallTool,                access: :read
            register Concierge::Tools::RememberTool,              access: :write
            register Concierge::Tools::ForgetTool,                access: :write
            register Concierge::Tools::SetOutreachPreferenceTool, access: :write
            register Concierge::Tools::RoutineTool,               access: :write
          end

          authority { default :autonomous }
        end

        c.agent :billing do
          persona name: "Bill", voice: "precise and factual, never chatty"

          playbook do
            product_brief "Acme bills monthly per seat. Invoices go out on the 1st."
            goals "Keep every account's billing accurate and their invoices paid on time."
            engagement_signal(:plan)       { |s| s[:plan] }
            engagement_signal(:seat_count) { |s| s.scope_for(:users).count }
          end

          capabilities do
            register Concierge::Tools::RecallTool,   access: :read
            register Concierge::Tools::RememberTool, access: :write
          end

          authority do
            default                :human_approval
            action "money.refund", :human_execution
          end
        end
      end
    end
  end

  module Test
    # The Slack half of the host's config (design §10.7). Separate from
    # +configure_agents!+ on purpose: an un-Slacked host is the default, and every
    # test that does not call this proves the approval queue works without a chat
    # transport at all — which is the property that makes an outage cost
    # convenience and not authority.
    #
    # Returns the recording transport so the test can assert on what Slack was
    # asked to do.
    def self.configure_slack!(cap: nil, actor_for: nil, channels: { csm: "C0CSM", billing: "C0BILLING" })
      transport = SlackTransport.new

      # Declaring a block twice re-opens it everywhere in this DSL, so a test that
      # reconfigures Slack starts from a fresh Settings rather than inheriting the
      # channels of the call before it.
      Concierge.config.remove_instance_variable(:@slack) if Concierge.config.instance_variable_defined?(:@slack)

      Concierge.configure do |c|
        c.slack do
          signing_secret SlackRequests::SECRET
          transport transport.to_proc
          daily_card_cap cap if cap
          actor_for actor_for if actor_for
          channels.each { |slug, id| channel slug, id }
        end

        c.proposal_notifier = Concierge::Slack::Notifier
      end

      transport
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
