# Concierge configuration for the dummy host app.
#
# Runs under `bin/rails server`, so the engine's admin surface and chat endpoint
# can be exercised by hand. See db/seeds.rb for sample data.
#
# This host is *pluralized*: it declares two business functions over the same
# Tenants (design §10.1). The single-agent form — top-level `playbook` and
# `capabilities` with no `agent` block at all — is what
# test/support/dummy_config.rb configures, so the suite keeps exercising the
# back-compat path on every run.

Rails.application.config.to_prepare do
  Concierge.configure do |c|
    c.default_model    = "claude-sonnet-4-5"
    c.default_provider = :anthropic

    # Without an API key there is nothing to talk to, so fall back to a scripted
    # reply. This keeps the dummy app usable offline; set ANTHROPIC_API_KEY to
    # drive a real model instead.
    unless ENV["ANTHROPIC_API_KEY"]
      c.chat_factory = ->(model:, chat_record: nil) { Dummy::ScriptedChat.new }
    end

    c.account do
      subject_class Tenant
      grain :account
      attribute(:name) { |t| t.name }
      attribute(:plan) { |t| t.plan }
      scope(:users)    { |t| t.users }
    end

    c.channels          = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
    c.email_address_for = ->(subject) { subject.to_model.users.first&.email }
    c.mailer_host       = "localhost:3000"

    # The admin fails closed without this hook. The dummy app has no real auth,
    # so allow it in development only — a host app would check its own session.
    c.authenticate_admin = ->(_controller) { Rails.env.development? }

    # Who is tapping Approve on a rule proposal. A real host returns
    # current_user.email; without this hook the maker-checker gate refuses rather
    # than inventing an approver (design §10.2).
    c.admin_actor = ->(_controller) { "operator@acme.test" }

    # Named segments a rule can target, so "for EU accounts, cite the DPA" does not
    # have to be written out per account.
    c.segments_for = ->(subject) { subject[:plan] == "enterprise" ? [ "enterprise" ] : [] }

    # Rules are drafted from human corrections by a deterministic generalizer
    # unless a host replaces it (`c.rule_generalizer`). Left at the default here so
    # the dummy app needs no model to exercise the write path.
    #
    # Where a proposal card gets posted is the host's call; without a notifier the
    # card still lives on /concierge/admin/rules.
    c.rule_proposal_notifier = lambda do |rule|
      Rails.logger.info("[dummy] rule ##{rule.id} proposed for #{rule.agent_slug}: #{rule.body}")
    end

    c.weekly_review_enabled     = true
    c.weekly_review_instruction = "Review this account and reach out if something is worth their attention."
    c.priority = ->(subject) { subject[:plan] == "enterprise" ? 100 : 1 }

    # --- Proposals: where the engine's authority ends (design §10.6/§10.8) -----
    # An action an agent may not perform itself is staged as an AgentProposal and
    # waits on /concierge/admin/proposals. The engine dispatches `message.*`
    # itself; anything the *host* owns needs an executor here.

    # A proposal nobody acts on for a fortnight has to be re-drafted against
    # current state rather than executed late.
    c.proposal_ttl = 14.days

    c.proposal_notifier = lambda do |proposal|
      Rails.logger.info("[dummy] proposal ##{proposal.id} (#{proposal.action_class}) " \
                        "awaiting a human for #{proposal.agent_slug}")
    end

    c.proposals do
      # A record mutation the engine performs *after* a human approves it. It gets
      # the resolved Scope, so it never looks an account up by a raw id.
      execute "record.plan_change" do |proposal, scope|
        scope.subject.to_model.update!(plan: proposal.action_arguments[:to])
      end

      # ...and what that proposal assumed. If the plan changed between the draft
      # and the approval, the approval was about a different world: the execution
      # refuses instead of overwriting whatever happened in between.
      precondition("record.plan_change") { |scope| { "plan" => scope.subject[:plan] } }

      # NOTE there is deliberately no `money.refund` executor. :billing gates it to
      # :human_execution, so the engine records the decision and a human performs
      # it — and a host's own refund seam re-checks human origination itself
      # (design §10.8). An engine that could execute this is the thing §10.8 exists
      # to prevent.
    end

    # --- Two business functions over the same Tenants (design §10.1) ----------
    # Each agent block carries the six slots: identity/persona/model, charter,
    # tool scope, authority envelope, memory namespace (the slug), kill switch.

    c.agent :csm do
      persona name: "Kit", voice: "warm, concise, never pushy"

      playbook do
        product_brief "Acme helps teams publish changelogs."
        goals "Get each account to publish their first changelog and upgrade."
        account_types :brand, :creator
        engagement_signal(:has_paid_plan) { |s| %w[pro enterprise].include?(s[:plan]) }
        engagement_signal(:user_count)    { |s| s.scope_for(:users).count }
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

      # Least privilege: billing reads and writes its own notes, and that is all.
      # No outreach-preference tool, no routines — it has no business scheduling
      # the customer's week.
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

module Dummy
  # Offline stand-in for a RubyLLM chat, mirroring the fluent surface
  # Concierge::Run drives. Unlike the test FakeChat this isn't scripted per
  # call — it just answers, so the dummy app works without an API key.
  class ScriptedChat
    Reply = Struct.new(:content, :tool_calls, :input_tokens, :output_tokens, keyword_init: true)

    def with_instructions(_text, replace: false) = self
    def with_temperature(_value) = self
    def with_context(_context)   = self
    def with_params(**)          = self
    def with_tools(*)            = self

    def ask(_prompt)
      reply = Reply.new(
        content: "Thanks for reaching out! I can see you're on the Pro plan and " \
                 "haven't published a changelog yet. Want me to walk you through it?",
        tool_calls: [], input_tokens: 320, output_tokens: 48
      )
      yield reply if block_given?
      reply
    end
  end
end
