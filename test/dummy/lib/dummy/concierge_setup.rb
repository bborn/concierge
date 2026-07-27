module Dummy
  # The dummy host's Concierge configuration, in one place so that the running
  # app (config/initializers/concierge.rb) and the host-surface integration tests
  # configure the engine *identically*. A demo whose tests exercise a different
  # config than the server is a demo that proves nothing.
  #
  # This host is pluralized (design §10.1): it declares two business functions
  # over the same Tenants. The single-agent form — top-level `playbook` and
  # `capabilities` with no `agent` block at all — is what
  # test/support/dummy_config.rb configures, so the suite keeps exercising the
  # back-compat path on every run.
  module ConciergeSetup
    module_function

    def apply(c)
      runtime(c)
      account(c)
      channels(c)
      admin(c)
      rules(c)
      proposals(c)
      slack(c)
      agents(c)
    end

    def runtime(c)
      c.default_model    = "claude-sonnet-4-5"
      c.default_provider = :anthropic

      # Without an API key there is nothing to talk to, so fall back to a
      # scripted reply. This keeps the dummy app usable offline; set
      # ANTHROPIC_API_KEY to drive a real model over the same prompt instead.
      #
      # The stand-in is handed the host Chat the engine resolved, and writes both
      # halves of the turn into it. A host's chat_factory owns its own persistence
      # semantics, and this one persists — so the offline demo has a real
      # transcript to show on every screen that reads the host's chat tables,
      # rather than only the stand-ins the seeds insert by hand.
      return if ENV["ANTHROPIC_API_KEY"]

      c.chat_factory = ->(model:, chat_record: nil) { Dummy::ScriptedChat.new(chat_record) }
    end

    def account(c)
      c.account do
        subject_class Tenant
        grain :account
        attribute(:name) { |t| t.name }
        attribute(:plan) { |t| t.plan }
        scope(:users) { |t| t.users }
        # The product surface, reachable from a tool or a signal without any
        # seam ever taking a raw tenant id it looks up globally.
        scope(:changelog_entries) { |t| t.changelog_entries }
      end
    end

    def channels(c)
      c.channels          = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
      c.email_address_for = ->(subject) { subject.to_model.users.first&.email }
      c.mailer_host       = "localhost:3000"

      # In-app delivery has to actively surface, and it has to leave the customer
      # something to read. The engine's audit row keeps a digest; the host keeps
      # the words (see InboxMessage).
      c.in_app_broadcaster = ->(subject, payload) { InboxMessage.record!(subject, payload) }
    end

    def admin(c)
      # The admin fails closed without this hook. The dummy app has no real auth,
      # so allow it locally only — a host app would check its own session.
      c.authenticate_admin = ->(_controller) { Rails.env.local? }

      # Who is tapping Approve on a proposal. A real host returns
      # current_user.email; without this hook the maker-checker gate refuses
      # rather than inventing an approver (design §10.2).
      c.admin_actor = ->(_controller) { "operator@acme.test" }

      # What to call an account on screen. Without this every surface reads
      # `account#1`, which is correct and unreadable — the operator working the
      # queue knows "Acme", not the primary key. Display only: the engine still
      # finds, scopes and audits every row by (subject_type, subject_id), and
      # nothing looks a subject up by this string.
      c.subject_label = ->(subject) { Tenant.find_by(id: subject.id)&.name }

      # ...and who may drive an account's agent over the engine's own endpoints.
      # The chat endpoint takes the account out of the URL, so without this a
      # signed-in customer could hand-craft a POST naming another tenant's
      # subject_id. The engine controllers are the *engine's*, not this app's, so
      # there is no current_user on them: the session is the seam.
      c.authorize_subject = lambda do |controller, scope|
        user = User.find_by(id: controller.session[:user_id])
        user && user.tenant_id.to_s == scope.subject.id.to_s
      end

      # A different question, so a different hook. The handoff endpoints seize a
      # customer's thread, speak on it as Acme, and land what is said as pinned
      # human memory in that agent's head — so the question is "are you staff",
      # and the tenant match above is exactly the wrong answer to it: Dana passes
      # it about her own account and would be support-splaining to herself.
      #
      # Staff sign in through their own door here (Support in the picker), which
      # sets no user_id at all — the two sessions are disjoint on purpose, so
      # neither hook can accidentally satisfy the other.
      #
      # A real host would narrow by scope as well — "...and is this account in
      # your book", or "only the on-call operator may take the billing thread" —
      # which is why the hook is handed the Scope and not just the controller.
      # This demo has one book with every account in it, so it does not.
      c.authorize_operator = ->(controller, _scope) { Operator.signed_in?(controller.session) }

      # ...and who that operator *is*. The engine records this on the takeover and
      # the product shows it to the customer ("support@acme.test has taken this
      # conversation over"), so it comes off the staff session the hook above just
      # vouched for. It used to come from the request, which meant Support could
      # seize Dana's thread under the CEO's name and Dana would be told so.
      #
      # A real host returns the signed-in staff member's email; this demo has one
      # seat, so the session holds it directly.
      c.operator_actor = ->(controller, _scope) { Operator.email(controller.session) }
    end

    def rules(c)
      # Named segments a rule can target, so "for EU accounts, cite the DPA" does
      # not have to be written out per account.
      c.segments_for = ->(subject) { subject[:plan] == "enterprise" ? [ "enterprise" ] : [] }

      # Rules are drafted from human corrections by a deterministic generalizer
      # unless a host replaces it (`c.rule_generalizer`). Left at the default so
      # the dummy app needs no model to exercise the write path.
      c.rule_proposal_notifier = lambda do |rule|
        Rails.logger.info("[dummy] rule ##{rule.id} proposed for #{rule.agent_slug}: #{rule.body}")
      end

      c.weekly_review_enabled     = true
      c.weekly_review_instruction = "Review this account and reach out if something is worth their attention."
      c.priority = ->(subject) { subject[:plan] == "enterprise" ? 100 : 1 }
    end

    # --- Proposals: where the engine's authority ends (design §10.6/§10.8) -----
    # An action an agent may not perform itself is staged as an AgentProposal and
    # waits on /concierge/admin/proposals. The engine dispatches `message.*`
    # itself; anything the *host* owns needs an executor here.
    def proposals(c)
      # A proposal nobody acts on for a fortnight has to be re-drafted against
      # current state rather than executed late.
      c.proposal_ttl = 14.days

      c.proposals do
        # A record mutation the engine performs *after* a human approves it. It
        # gets the resolved Scope, so it never looks an account up by a raw id.
        execute "record.plan_change" do |proposal, scope|
          # A knob, not a feature: `SLOW_EXECUTOR=4` makes this host executor take
          # longer than Slack is willing to wait, which is the only way to see by
          # hand that the interactivity endpoint no longer waits for it (§10.7).
          # Every real host executor that talks to a payment provider is this,
          # without the env var.
          sleep Float(ENV["SLOW_EXECUTOR"]) if ENV["SLOW_EXECUTOR"].present?
          scope.subject.to_model.update!(plan: proposal.action_arguments[:to])
        end

        # ...and what that proposal assumed. If the plan changed between the
        # draft and the approval, the approval was about a different world: the
        # execution refuses instead of overwriting whatever happened in between.
        precondition("record.plan_change") { |scope| { "plan" => scope.subject[:plan] } }

        # NOTE there is deliberately no `money.refund` executor. :billing gates it
        # to :human_execution, so the engine records the decision and a human
        # performs it — and a host's own refund seam re-checks human origination
        # itself (design §10.8).
      end
    end

    # --- Slack as the remote control (design §10.7) ----------------------------
    # Offline by default: without SLACK_BOT_TOKEN the Web API calls are answered
    # by a local stand-in that logs them, so `bin/rails db:seed` produces real
    # SlackCard rows with no network and no workspace.
    def slack(c)
      c.slack do
        signing_secret ENV.fetch("SLACK_SIGNING_SECRET", "dummy-signing-secret")
        bot_token      ENV["SLACK_BOT_TOKEN"]

        channel :csm,     ENV.fetch("SLACK_CSM_CHANNEL", "C0CSMDEMO")
        channel :billing, ENV.fetch("SLACK_BILLING_CHANNEL", "C0BILLINGDEMO")

        # Deliberately tiny so the anti-noise cap is visible by hand, and every
        # suppressed card is still decidable on /concierge/admin/proposals.
        daily_card_cap 2

        # Who clicked. A real host looks the Slack user up in its own tables.
        actor_for ->(user) { User.find_by(email: "dana@acme.test")&.email if user["id"] == "UDANA" }

        unless ENV["SLACK_BOT_TOKEN"]
          transport lambda { |method, payload|
            Rails.logger.info("[dummy] slack #{method} -> #{payload[:channel] || payload[:trigger_id]}")
            { "ok" => true, "channel" => payload[:channel],
              "ts" => format("%.6f", Time.current.to_f) }
          }
        end
      end

      c.proposal_notifier = Concierge::Slack::Notifier
    end

    # --- Two business functions over the same Tenants (design §10.1) ----------
    # Each agent block carries the six slots: identity/persona/model, charter,
    # tool scope, authority envelope, memory namespace (the slug), kill switch.
    def agents(c)
      c.agent :csm do
        persona name: "Kit", voice: "warm, concise, never pushy"

        playbook do
          product_brief "Acme helps teams publish changelogs."
          goals "Get each account to publish their first changelog and upgrade."
          account_types :brand, :creator
          engagement_signal(:plan)          { |s| s[:plan] }
          engagement_signal(:has_paid_plan) { |s| %w[pro enterprise].include?(s[:plan]) }
          engagement_signal(:user_count)    { |s| s.scope_for(:users).count }
          # The charter is "get each account to publish their first changelog",
          # so whether they have is the signal the agent most needs.
          engagement_signal(:published_changelogs) { |s| s.scope_for(:changelog_entries).published.count }
          engagement_signal(:draft_changelogs)     { |s| s.scope_for(:changelog_entries).drafts.count }
          engagement_signal(:days_since_active) do |s|
            last = s.to_model.last_active_at
            last ? ((Time.current - last) / 1.day).floor : nil
          end
        end

        capabilities do
          register Concierge::Tools::RecallTool,                access: :read
          register Concierge::Tools::RememberTool,              access: :write
          register Concierge::Tools::ForgetTool,                access: :write
          register Concierge::Tools::SetOutreachPreferenceTool, access: :write
          register Concierge::Tools::RoutineTool,               access: :write
        end

        # Autonomous within caps — the standing guidance, unchanged.
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

        # Least privilege: billing reads and writes its own notes, and that is
        # all. No outreach-preference tool, no routines.
        capabilities do
          register Concierge::Tools::RecallTool,   access: :read
          register Concierge::Tools::RememberTool, access: :write
        end

        # Money always gates to a human, and billing proposes rather than acts.
        authority do
          default                :human_approval
          action "money.refund", :human_execution
        end

        enabled true
      end
    end
  end
end
