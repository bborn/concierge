# Concierge

A per-account AI customer success manager for Rails, built on
[RubyLLM](https://rubyllm.com). Mount the engine, tell it three things — *what an
account is*, *what your app does and what "engaged" means*, and *what the agent
may touch* — and every account gets a durable, always-on agentic CSM: one
persistent conversation per account that reads activation/engagement state,
remembers what it learns, acts on a schedule, and reaches customers across
pluggable channels — reactively and proactively, **autonomously within caps**,
with a human able to take over any thread at any time (and the agent learning
from that takeover).

## The six boundaries

| Boundary | What the host supplies |
|---|---|
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

## Using it

Reactive (a customer message → a reply):

```ruby
result = Concierge::Run.reactive(subject, "How do I publish a changelog?")
result.reply_text
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
high-confidence memory that steers future runs. To require human approval on
every send instead, set `config.draft_and_review = true`.

## Security

Every tool and query is account-scoped through the current `Subject` — a tool
can never reach another account's data. Write tools are grant-gated. Prompt
injection is mitigated by least-privilege grants, an audit log, and fast human
takeover. `RubyLLM.context` isolates per-tenant credentials; data isolation is
enforced by the gem.

## Out of scope (v1)

Hosted SaaS control plane; vector/semantic memory; non-Rails hosts;
customer-connected MCP; Slack outbound; cross-account agent coordination.

## License

MIT.
