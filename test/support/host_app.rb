module Concierge
  module Test
    # Shared setup for the host-surface integration tests.
    #
    # It configures Concierge with `Dummy::ConciergeSetup` — the *same* module
    # config/initializers/concierge.rb hands to `Concierge.configure` when you run
    # `bin/rails server`. A demo whose tests exercise a different configuration
    # than the server does is a demo that proves nothing, so these tests get the
    # real two-agent host: Kit autonomous, Bill gated to :human_approval, the
    # host's `record.plan_change` executor and its precondition, in-app deliveries
    # landing in the customer's inbox.
    #
    # The chat factory is the one exception, and only by omission: ConciergeSetup
    # installs its offline stand-in *unless* ANTHROPIC_API_KEY is set, and
    # test_helper always sets one, so FakeChat survives and no test ever reaches a
    # model.
    module HostApp
      extend ActiveSupport::Concern

      included do
        setup do
          Concierge.configure { |c| Dummy::ConciergeSetup.apply(c) }

          @acme = Tenant.create!(name: "Acme Corp", plan: "pro", last_active_at: 2.days.ago)
          @dana = @acme.users.create!(email: "dana@acme.test")

          @globex = Tenant.create!(name: "Globex", plan: "enterprise", last_active_at: 1.hour.ago)
          @hank   = @globex.users.create!(email: "hank@globex.test")
        end
      end

      def sign_in_as(user)
        post signin_path, params: { user_id: user.id }
      end

      def csm_scope(tenant)     = scope_for(:csm, tenant)
      def billing_scope(tenant) = scope_for(:billing, tenant)

      def scope_for(slug, tenant)
        Concierge::Scope.new(
          Concierge.config.agent(slug),
          Concierge.config.account.find_subject(tenant.id)
        )
      end

      # Deliver an in-app message the way the app does — through Outreach, so the
      # host's in_app_broadcaster runs and the InboxMessage is written under the
      # same token the ChannelDelivery is recorded under.
      def deliver_in_app(scope, body, sent_at: Time.current, kind: "outreach")
        Concierge::Outreach.dispatch(
          scope, { body: body, kind: kind }, channel: :in_app, kind: kind,
          governance: Concierge::Governance.new(now: sent_at)
        )
      end

      # CSRF is off in the test environment by default, which is exactly why the
      # engine's chat endpoint had never been exercised the way a browser drives
      # it. Turning it on for one test is the only way to prove the pairing.
      def with_forgery_protection
        original = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        yield
      ensure
        ActionController::Base.allow_forgery_protection = original
      end

      def csrf_token_from_page
        css_select("meta[name=csrf-token]").first["content"]
      end

      # ActionDispatch builds url_options from the *last* controller it hit, so a
      # host path helper used straight after a request into the mounted engine
      # comes back with "/concierge" on the front of it. Tests that cross back
      # from the admin into the product use literal paths for that reason.
    end
  end
end
