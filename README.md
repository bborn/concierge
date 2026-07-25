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
end
```

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
high-confidence memory that steers future runs. Takeover is per (agent,
account), so holding the disputes thread does not silence the CSM.

Per-agent authority is the general form (see `authority` above). The older
global `config.draft_and_review = true` still works and still only *tightens*:
it routes every agent's sends to the outbox for human approval.

## Security

Every tool and query is scoped to the current **(agent, account)** pair — a tool
can never reach another account's data, nor another agent's notes about the same
account. Write tools are grant-gated. Prompt injection is mitigated by
least-privilege grants, an audit log, and fast human takeover. `RubyLLM.context`
isolates per-tenant credentials; data isolation is enforced by the gem.

## Out of scope (v1)

Hosted SaaS control plane; vector/semantic memory; non-Rails hosts;
customer-connected MCP; Slack outbound; cross-account agent coordination.

## License

MIT.
