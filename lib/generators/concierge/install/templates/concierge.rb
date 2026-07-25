# Concierge configuration. Tell the gem what an account is, what your app does,
# what the agent may touch, and how it may reach the customer.
Concierge.configure do |config|
  config.default_model = "claude-sonnet-4-5"

  # 1. What is an account? Map your host model to Concierge's Subject.
  config.account do
    subject_class Account        # your team/tenant/workspace model
    grain :account               # :account (default) or :user
    attribute(:name) { |a| a.name }
    attribute(:plan) { |a| a.plan }
    # scope(:reports) { |a| a.reports }   # account-scoped relations tools may read
  end

  # 2. What does the app do, and what does "engaged" mean?
  config.playbook do
    product_brief "Describe your product in a sentence or two."
    goals "What does success look like for an account?"
    engagement_signal(:has_paid_plan) { |s| s[:plan] != "free" }
    # engagement_signal(:reports_created) { |s| s.scope_for(:reports).count }
    persona name: "Your Agent's Name", voice: "warm, concise, never pushy"
  end

  # 3. What may the agent touch? Register tools with least-privilege grants.
  config.capabilities do
    register Concierge::Tools::RecallTool,                access: :read
    register Concierge::Tools::RememberTool,              access: :write
    register Concierge::Tools::ForgetTool,                access: :write
    register Concierge::Tools::SetOutreachPreferenceTool, access: :write
    register Concierge::Tools::RoutineTool,               access: :write
  end

  # 4. How may it reach the customer?
  config.channels          = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
  config.email_address_for = ->(subject) { subject.to_model.owner_email }
  config.mailer_host       = "your-app.example.com"

  # 5. Proactivity + cost governance (optional).
  config.weekly_review_enabled     = true
  config.weekly_review_instruction = "Review this account and reach out if something is worth their attention."
  config.budget = { per_tenant: 200_000, global: 5_000_000 } # daily token caps

  # 6. Autonomy. Concierge is autonomous within caps by default. Flip this on to
  # gate every agent's sends to human approval instead. (The general form is the
  # per-agent `authority` block in 10 below; this flag only ever *tightens*.)
  # config.draft_and_review = true

  # 7. Guard the admin surface. Return truthy to allow.
  # config.authenticate_admin = ->(controller) { controller.current_user&.admin? }
  #
  # ...and say who is driving it, so approving a rule records a real approver.
  # Without this, the rule gate refuses rather than inventing one.
  # config.admin_actor = ->(controller) { controller.current_user.email }

  # 8. Rules — generalized, versioned, human-gated behavioral instructions, split
  # out from memory. A human correction is stored verbatim and a background job
  # drafts a rule from it; the rule is inert until a human approves it at
  # /concierge/admin/rules. All optional:
  #
  # config.active_rule_cap        = 12      # active rules per scope; hitting it blocks
  # config.rule_generalizer       = ->(correction) { ... }  # your own drafting pass
  # config.rule_proposal_notifier = ->(rule) { Slack.post_card(rule) }
  # config.segments_for           = ->(subject) { subject[:region] == "eu" ? [ "eu" ] : [] }
  #
  # Every completed run records what was in its prompt (memories, rule versions,
  # snapshot digest). That is real write volume — prune on your own cadence:
  #
  #   Concierge::AgentRun.prune!(older_than: 90.days)
  #
  # And schedule the weekly consolidation pass, which only ever *proposes*:
  #
  #   concierge_dreaming:
  #     class: Concierge::RuleDreamingJob
  #     schedule: every sunday at 3am

  # 9. Proposals — actions an agent may propose but not perform. Anything its
  # authority envelope does not make :autonomous stages as a Concierge::AgentProposal
  # and waits on /concierge/admin/proposals. Maker-checker (the proposer can never
  # approve), preconditions re-validated at execution, exactly-once execution.
  #
  # The engine dispatches `message.*` itself. Anything YOUR app owns needs an
  # executor — and this is where engine authority ends and your invariants begin:
  # the executor re-checks them on its own terms, so even a bug in the engine
  # cannot get past your own guard.
  #
  # config.proposals do
  #   execute("record.plan_change") { |proposal, scope| scope.subject.to_model.update!(proposal.action_arguments) }
  #
  #   # What the proposal assumed. Re-digested at execution; a mismatch refuses
  #   # rather than acting on a decision that was about a different world.
  #   precondition("record.plan_change") { |scope| { plan: scope.subject[:plan] } }
  #
  #   # Register by exact class, by prefix ("record.*") or "*". Most specific wins.
  # end
  #
  # config.proposal_ttl      = 14.days                        # nil (default) = never expire
  # config.proposal_notifier = ->(proposal) { YourMailer.approval(proposal).deliver_later }
  #
  # Expiry rides on the sweep you already registered above. Money should stay at
  # :human_execution: the engine records the decision and never performs it.

  # 9b. Slack as the remote control for that queue. A real Slack app, not an
  # incoming webhook — a webhook cannot tell you WHO clicked, and an approval with
  # an unknown approver is not maker-checked. Point the app's Interactivity URL at
  # POST /concierge/slack/interactions and its Events URL at
  # POST /concierge/slack/events; both verify Slack's signature over the raw body
  # and 404 without a signing secret.
  #
  # config.slack do
  #   signing_secret ENV["SLACK_SIGNING_SECRET"]
  #   bot_token      ENV["SLACK_BOT_TOKEN"]
  #
  #   channel :csm,      "C0CSM"        # one channel per agent, one thread per case
  #   channel :disputes, "C0DISPUTES"
  #
  #   daily_card_cap 20                 # anti-noise: over it, the card is not posted
  #   actor_for ->(user) { User.find_by(slack_id: user["id"])&.email }
  # end
  #
  # config.proposal_notifier = Concierge::Slack::Notifier
  #
  # A click writes the decision to the proposal row FIRST, then executes, then
  # updates the card — the card is last and may fail, because Postgres is the
  # record and /concierge/admin/proposals is the same queue. Autonomous work is
  # never carded; schedule Concierge::SlackDigestJob and each agent summarises its
  # own unilateral sends in one message.

  # 10. More than one business function? Everything above is the implicit :csm
  # agent. Declare agents explicitly to run several over the same accounts, each
  # with its own persona, charter, tools, authority envelope, memory namespace
  # (the slug) and kill switch. State is keyed by (agent, account), so no agent
  # reads another's notes.
  #
  # config.agent :disputes do
  #   persona name: "Dee", voice: "precise and factual"
  #   playbook { product_brief "..." }
  #   capabilities { register Concierge::Tools::RecallTool, access: :read }
  #   authority do
  #     default                :human_approval   # propose; a human approves
  #     action "money.refund", :human_execution  # money always gates to a human
  #   end
  # end
end
