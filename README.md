# Concierge

A per-(business-function) AI agent engine for Rails, built on
[RubyLLM](https://rubyllm.com). Mount the engine, tell it three things — *what an
account is*, *what your app does and what "engaged" means*, and *what the agent
may touch* — and every account gets a durable, always-on agent: one persistent
conversation per (agent, account) that reads activation/engagement state,
remembers what it learns, acts on a schedule, and reaches customers across
pluggable channels — reactively and proactively, **autonomously within caps**,
with a human able to take over any thread at any time (and the agent learning
from that takeover).

The customer success manager is agent #1, not the whole engine: declare as many
business functions as you need and they run over the same accounts, isolated
from each other.

## The boundaries

| Boundary | What the host supplies |
|---|---|
| **Agent** | A business function: persona, charter, tools, authority, kill switch |
| **AccountAdapter** | Maps a host model → a generic `Subject` |
| **Playbook** | Product brief, engagement signals, persona |
| **ContextStore** | Durable agent- and human-writable memory |
| **Capability layer** | Account-scoped RubyLLM tools (+ MCP seam) |
| **ChannelBridge** | Pluggable delivery + governance + human takeover |
| **Routines + Runtime** | Reactive/proactive agent loop + scheduling |

## Installation

Add to your Gemfile:

```ruby
gem "concierge"
```

Then install (this also mounts the engine and writes a config initializer):

```bash
bundle install
bin/rails generate concierge:install
bin/rails db:migrate
```

Concierge builds on RubyLLM's `Chat`/`Message`/`ToolCall` models. If you don't
have them yet, run `bin/rails generate ruby_llm:install` first. Do **not** add
`validates :content, presence: true` to the `Message` model — RubyLLM writes the
assistant message empty first.

## Configuration

Everything is declared in `config/initializers/concierge.rb`:

```ruby
Concierge.configure do |config|
  config.default_model = "claude-sonnet-4-5"

  config.account do
    subject_class Account
    attribute(:name) { |a| a.name }
    attribute(:plan) { |a| a.plan }
    scope(:reports)  { |a| a.reports }
  end

  config.playbook do
    product_brief "Acme helps teams publish changelogs."
    engagement_signal(:has_paid_plan)   { |s| s[:plan] != "free" }
    engagement_signal(:reports_created) { |s| s.scope_for(:reports).count }
    persona name: "Kit", voice: "warm, concise, never pushy"
  end

  config.capabilities do
    register Concierge::Tools::RecallTool,   access: :read
    register Concierge::Tools::RememberTool, access: :write
    register Concierge::Tools::RoutineTool,  access: :write
  end

  config.channels          = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
  config.email_address_for  = ->(subject) { subject.to_model.owner_email }
  config.weekly_review_enabled = true
  config.budget = { per_tenant: 200_000, global: 5_000_000 }

  # Who may act as an account on the engine's own endpoints. Required — see below.
  config.authorize_subject = lambda do |controller, scope|
    user = User.find_by(id: controller.session[:user_id])
    user && user.account_id.to_s == scope.subject.id.to_s
  end
end
```

### Who may act as an account

Two engine surfaces take an account out of the URL: the chat endpoint
(`POST /concierge/accounts/:subject_id/chat`) and the operator handoff endpoints
beside it. The engine cannot know your app's session shape, so it asks — and,
like the admin, **fails closed**: without `config.authorize_subject` every
request to those endpoints is refused with a `403` and a log line saying so.

The hook is handed the controller (read your own session off it — these are the
*engine's* controllers, so there is no `current_user` on them unless you put one
there) and the resolved `Scope`, so an answer can be per **(agent, account)**:

```ruby
config.authorize_subject = lambda do |controller, scope|
  user = User.find_by(id: controller.session[:user_id])
  next false unless user && user.account_id.to_s == scope.subject.id.to_s

  scope.agent_slug != "billing" || user.support_staff?
end
```

An account that does not exist is refused exactly as an account that is not yours
is, so the endpoint is not an id oracle. `/concierge/admin/*` keeps its own
`config.authenticate_admin` — "are you staff" and "is this account yours" are
different questions, and neither stands in for the other. The unsubscribe link is
authorized by its token and needs neither.

## More than one business function

Everything above is the implicit `:csm` agent. Declare agents explicitly to run
several over the same accounts. Each block carries six slots —
identity/persona/model, charter, tool scope, authority envelope, memory
namespace (its slug), and a kill switch:

```ruby
config.agent :disputes do
  persona name: "Dee", voice: "precise and factual"

  playbook do
    product_brief "Acme bills monthly per seat."
    engagement_signal(:open_disputes) { |s| s.scope_for(:disputes).open.count }
  end

  # Least privilege per function: an off-scope tool is not registered, so it
  # does not exist in this agent's loop rather than existing and erroring.
  capabilities do
    register Concierge::Tools::RecallTool,   access: :read
    register Concierge::Tools::RememberTool, access: :write
  end

  authority do
    default                :human_approval   # propose; a human approves
    action "money.refund", :human_execution  # money always gates to a human
  end

  enabled true                               # flip to false to halt this agent
end
```

State is keyed by the **(agent, account)** pair: memory, conversations,
routines, deliveries, budget rows, handoffs and drafted proposals all carry an
`agent_slug`, and no query crosses either dimension. Facts every agent on an
account legitimately shares go in the reserved `_shared` namespace
(`remember(scope, …, shared: true)`); reads fold it in automatically.

Two things stay deliberately per-*customer* rather than per-agent, because the
customer has one inbox: outreach preferences (opt-out, quiet hours, cadence) and
the frequency cap and per-tenant token budget that read across every agent.

## Memory vs. rules

Two different things used to live in `concierge_memories`, and they behave
differently, so they are two tables:

| | **Memory** | **Rule** |
|---|---|---|
| what it is | an episodic fact about one relationship | a generalized instruction about how to behave |
| example | *"Renewal is in March."* | *"Never promise a delivery date without checking the API."* |
| scope | (agent, account) | (agent) &times; optionally a segment or one account |
| lifecycle | write, pin, retire | `proposed` &rarr; `active` &rarr; `deprecated`, versioned |
| who can create it | the agent, a tool, a human | anyone may **propose** |
| who can put it in force | whoever wrote it | **only a human, and never its own author** |

A rule reaches a run through a Playbook section of the prompt, rendered with its
id and version so the agent can cite what it applied:

```
Playbook — the rules in force here. A human approved each one; ...
- [rule 12 v2] Never promise a delivery date; point them at the status page.
- [rule 31 v1] Acme's CEO is skeptical of AI tooling — keep the tone low-key.
```

### The write path

A human correction is stored **verbatim** as memory, and — when it reads as an
instruction rather than a fact — an out-of-band job drafts a rule from it,
conflict-checks it against what is already in force, and leaves it `proposed`:

```ruby
Concierge::Learning.capture(scope, content: "Never quote a delivery date without checking.")
# => verbatim memory + a RuleGeneralizerJob -> a proposed rule, waiting

Concierge::Rules.activate!(rule, by: "sam@acme.test")   # the human tap
```

The gate is structural, not conventional. `Rules.activate!` refuses an actor
prefixed `agent:` (which is how the engine's own jobs author), refuses the rule's
own author, refuses while a flagged conflict is unresolved, and refuses at the
per-scope **active-rule cap** — with the rules to consolidate named in the error.
Hitting the cap *blocks*; it never silently drops rules from a prompt.

Hosts can plug in their own drafting pass and their own card destination:

```ruby
config.active_rule_cap        = 12                       # per scope; nil = default
config.rule_generalizer       = ->(correction) { ... }   # LLM-backed if you like
config.rule_proposal_notifier = ->(rule) { Slack.post_card(rule) }
config.segments_for           = ->(subject) { subject[:region] == "eu" ? ["eu"] : [] }
config.admin_actor            = ->(controller) { controller.current_user.email }
```

A rule with `enforcement: "guard"` carries a declarative `predicate` the engine
checks itself, so the policy holds whether or not the model followed it:

```ruby
predicate: { "action_class" => "message.outreach",
             "deny_when"    => { "body" => { "matches" => "guarantee" } } }
```

### Provenance

Every completed run writes a `concierge_agent_runs` row: the memory ids and rule
`(id, version)` pairs that were in the prompt, the snapshot digest it reasoned
over, the model and tokens, and the rule ids the agent *claimed* to apply —
cross-checked against what was actually injected. Because rules keep an
append-only revision trail, a pinned version still resolves to the exact text
that was in force, even after the rule has been rewritten. Browse it at
`/concierge/admin/runs`; approve or retire rules at `/concierge/admin/rules`.

A weekly `Concierge::RuleDreamingJob` proposes consolidations and retirements
with evidence (a rule injected into N prompts and never once cited, two rules
that say the same thing, a rule already superseded). It only ever proposes.

Provenance is real write volume — one row per run. Prune on your own cadence:

```ruby
Concierge::AgentRun.prune!(older_than: 90.days)
```

## Using it

Reactive (a customer message → a reply):

```ruby
result = Concierge::Run.reactive(subject, "How do I publish a changelog?")
result.reply_text

# ...or name the business function that should answer:
scope = Concierge::Scope.new(Concierge.config.agent(:disputes), subject)
Concierge::Run.reactive(scope, "Where is my refund?")
```

Proactive runs happen on a schedule. Register the sweep once in
`config/recurring.yml`:

```yaml
production:
  concierge_sweep:
    class: Concierge::SweepJob
    schedule: every hour
```

The sweep enqueues per-account reviews for due routines and the built-in weekly
review, in priority order, skipping unchanged accounts and honoring token
budgets.

## Autonomy, governance, and takeover

Concierge is **autonomous within caps** by default: it sends without a
per-message approval gate, bounded by frequency caps, quiet hours, per-subject
opt-out, and one-click unsubscribe. Control is **human takeover**, not gating —
seize any thread via the handoff endpoints; while a human holds it, autonomous
proactive sends are suppressed and the operator's messages are captured as
high-confidence memory that steers future runs — and, when they read as an
instruction, as a proposed rule for a human to approve (see above). Takeover is
per (agent, account), so holding the disputes thread does not silence the CSM.

Per-agent authority is the general form (see `authority` above). The older
global `config.draft_and_review = true` still works and still only *tightens*:
it gates every agent's sends to human approval.

## Proposals — actions an agent may not perform itself

An agent's authority envelope names three levels per action class:
`:autonomous` (do it, within caps), `:human_approval` (propose it; a human
approves and **the engine** executes), and `:human_execution` (propose it; a
human approves **and performs it**). Anything short of `:autonomous` becomes a
`Concierge::AgentProposal` waiting on `/concierge/admin/proposals` — an outbound
message from a gated agent, a CRM update, a refund. All one object.

```ruby
Concierge::ApprovalIntake.approve(proposal, by: current_user.email)
Concierge::ApprovalIntake.reject(proposal,  by: current_user.email, reason: "wrong tone")
Concierge::ApprovalIntake.correct(proposal, by: current_user.email, payload: { body: "…" })
```

Four properties hold whatever surface drives that seam:

- **Maker-checker.** `created_by ≠ approved_by`, and an `agent:` actor can
  propose but never approve.
- **Execute only from an approved record.** There is no approve-and-execute call
  that skips the row; a rejection requires a reason.
- **Preconditions are re-validated at execution time.** The engine digests what
  the proposal assumed and re-checks it before dispatching — a customer who opted
  out between the draft and the approval is not messaged. Guard rules are
  re-checked here too, so a policy activated *after* the draft still binds it.
- **Exactly once**, per `idempotency_key`. A failed execution is never retried
  automatically; a human clears it after looking.

The engine dispatches `message.*` itself. Anything the host owns needs an
executor — this is where engine authority ends and host invariants begin:

```ruby
config.proposal_ttl = 14.days   # unapproved proposals expire (nil = never)

config.proposals do
  execute("record.plan_change") { |proposal, scope| scope.subject.to_model.update!(plan: proposal.action_arguments[:to]) }
  precondition("record.plan_change") { |scope| { plan: scope.subject[:plan] } }
end
```

Register an executor by exact class, by prefix (`"record.*"`), or `"*"`; most
specific wins. **The engine makes an action proposable; it does not enforce your
domain invariants.** Your `Orders::IssueRefund` still re-checks human
origination, amount limits, and order state on its own terms — so even a bug in
the engine cannot issue a refund past your guard. That is why money defaults to
`:human_execution`: the engine records the decision and never performs it.

The kill switch is read again at execution, not just at run start, so disabling
an agent also halts its already-approved work.

## Slack as the remote control

Delivery and approval **intake** are two seams. `Concierge::Channel::*` is
outbound-only and never raises; the click that comes *back* is a decision, and it
goes through `ApprovalIntake`. So Slack is not a channel here — it is a surface,
and it needs a real Slack app rather than an incoming webhook, because a webhook
cannot tell you *who clicked*.

```ruby
config.slack do
  signing_secret ENV["SLACK_SIGNING_SECRET"]
  bot_token      ENV["SLACK_BOT_TOKEN"]

  channel :csm,      "C0CSM"        # one channel per agent
  channel :disputes, "C0DISPUTES"

  daily_card_cap 20
  actor_for ->(user) { User.find_by(slack_id: user["id"])&.email }
end

config.proposal_notifier = Concierge::Slack::Notifier
```

Point the Slack app's **Interactivity** URL at `POST /concierge/slack/interactions`
and its **Events** URL at `POST /concierge/slack/events`. Both verify Slack's
`v0` signature over the raw body (five-minute replay window) before reading a
byte of the payload; with no signing secret configured, both answer 404.

A proposal arrives as a Block Kit card with **Approve**, **Reject** and
**Correct**. The handler order is fixed:

```
signed payload → write the decision to the proposal row → execute → update the card
```

The card is updated **last** and is allowed to fail. Postgres is the record; a
stale card with a correct row is recoverable, and the reverse would be a decision
that exists only in a chat message. Every decision is also available on
`/concierge/admin/proposals`, so a Slack outage costs convenience, not authority —
`/concierge/admin/slack` shows which cards posted, which the cap suppressed, and
which failed.

- **Reject requires a reason.** The button opens a modal; a blank or whitespace
  reason is refused there, not stored.
- **Correct** is edit-then-approve, offering one input per argument the agent
  actually proposed — a correction edits an action, it cannot author a new one.
  It also opens the rule write path: "what should the agent do differently next
  time?" becomes a **proposed** rule, never an active one.
- **A reply in a case thread** (one thread per `(agent, account)`) is captured as
  a takeover note through `Learning`, in that agent's namespace only.

Anti-noise is structural, not advisory: a **per-agent daily card cap** (over it,
the card is not posted and the suppression is recorded — the proposal is
untouched), **no bare `@channel`** (broadcast escapes in a model-written draft are
neutralized and flagged), and **digests instead of cards for unilateral work** —
schedule `Concierge::SlackDigestJob` and each agent reports its own autonomous
sends in one message.

## Security

Every tool and query is scoped to the current **(agent, account)** pair — a tool
can never reach another account's data, nor another agent's notes about the same
account. The engine's per-account HTTP endpoints ask the host who is calling
(`config.authorize_subject`, above) and refuse until it says. Write tools are
grant-gated. Prompt injection is mitigated by
least-privilege grants, an audit log, and fast human takeover — and by the rule
gate: nothing the model or a customer says can put a behavioral instruction into
force, because activation requires a human who is not the author. Guard-rule
predicates are declarative data, never evaluated as code. `RubyLLM.context`
isolates per-tenant credentials; data isolation is enforced by the gem.

## Try it: the Acme demo host

`test/dummy` is a small but real product — **Acme**, the changelog SaaS the `:csm`
playbook describes — with the agent living inside it.

```bash
cd test/dummy
bin/rails db:prepare && bin/rails db:seed
bin/rails server
open http://localhost:3000
```

Sign in as **Dana at Acme Corp · pro** (no passwords — the picker is an account
switcher, and switching accounts to watch what the agent knows change with you is
the point). From there:

1. **Changelog** — Acme's product. Dana has a draft and has published nothing,
   which is exactly what the CSM's charter is about.
2. **Kit** (bottom right) — the chat widget, posting to the engine's own
   `POST /concierge/accounts/:subject_id/chat` with this page's CSRF token. Ask
   "how do I publish my first changelog?"
3. **"Kit, take a look"** (in the widget, local environments only) — runs the
   proactive path now instead of next Monday, and reports what it decided:
   delivered, drafted for a human, or refused by governance.
4. **Inbox** — what the agent actually sent this account, with an unread count in
   the header, and a link to the run provenance behind it.
5. **Account → Request a plan change** — goes through the `:billing` agent's
   authority envelope, so the product says *your request is with our team* while
   an `AgentProposal` waits at `/concierge/admin/proposals`. Approve it there and
   come back: the plan has really changed.
6. **Account → Talk to a human** — opens a `Concierge::Handoff`; the agent
   visibly steps back until you hand the thread back.

It runs **offline**: with `ANTHROPIC_API_KEY` unset a scripted stand-in answers,
so a keyless host still works. Concierge notices the missing credential itself —
when the configured provider has no key it runs *without a persisted
conversation*, because persisting a `Chat` makes RubyLLM resolve a model, and
resolving instantiates the provider. Chat history stops being saved (and says so
in the log) but the turn still happens. A keyless host that has **not** supplied
an offline `chat_factory` gets a failed `Result` carrying the
`RubyLLM::ConfigurationError`, never a raise and never a false success.

Export a real key and the same UI drives a real model over the same prompt —
playbook, snapshot, memory, and the rules in force:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
cd test/dummy && bin/rails server
```

The operator's side of the same accounts is at `/concierge/admin/*`.

## Out of scope (v1)

Hosted SaaS control plane; vector/semantic memory; non-Rails hosts;
customer-connected MCP; Slack outbound; cross-account agent coordination.

## License

MIT.
