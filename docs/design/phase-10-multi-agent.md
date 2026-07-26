# Phase 10 — Multi-agent: the (Agent × Subject) engine

> **Status:** design, gated by human review (2026-07-23 decisions by Bruno).
> This section extends the approved Concierge design (§0–§8, ty-4887) and its
> phased plan (Phases 0–9). It is the **single source of truth** for the
> multi-agent generalization. OfferLab's `business-function-agents.md` (PR
> offerlab/offerlab#3324) should **reference** this section rather than
> re-specifying the runtime; its Phase 2 is folded in here.

---

## 10.0 Mission expansion

Concierge's mission grows from **"a per-account CSM engine"** to **"a general
per-(business-function) agent engine."** The customer success manager is no
longer *the* engine — it is **agent #1** (`:csm`). Lead-qualification, support,
and disputes agents are the same engine with different charters, tools, and
authority.

Everything in §0–§8 still holds. This phase changes exactly one thing at the
core and lets the rest follow: **identity becomes two-dimensional.**

- **Before:** the agent *is* the engine. Config is global (`Concierge.config`
  has one `account`, one `playbook`, one `capabilities`, one `draft_and_review`).
  Every `concierge_*` table is keyed by **Subject** alone
  (`SubjectScoped` = `subject_type` + `subject_id`).
- **After:** identity is **(Agent × Subject)**. An *Agent* is a first-class,
  host-declared configuration object; a *Subject* is still the host record the
  agent acts on. State is keyed by the **pair**.

The CSM already ships and must keep working untouched — so this is an
**expand/contract migration around a single new dimension**, not a rewrite.

---

## 10.1 The keystone decision: the (Agent × Subject) identity model

### Agent as a first-class concept

Add a repeatable config block. The existing global blocks become the body of one
agent:

```ruby
Concierge.configure do |c|
  c.agent :csm do
    # identity/persona/model, charter (Playbook), tool scope, authority
    # envelope, memory namespace, kill switch — the six slots below.
  end

  c.agent :disputes do
    # a second business function over the same Subjects.
  end
end
```

`config.agent(:slug)` with a block **defines**; bare `config.agent(:slug)` **reads
back** the resolved `Concierge::Agent`. `config.agents` returns all of them. This
mirrors the existing setter/reader DSL (`lib/concierge/dsl.rb`,
`Configuration#account/#playbook/#capabilities`) — the pattern is already in the
codebase; we make it plural.

### The six slots (doc §2.2)

Each agent definition carries exactly six slots. The table below maps each slot
to what exists today and where it lands:

| # | Slot | Today (global) | Under (Agent × Subject) |
|---|------|----------------|--------------------------|
| 1 | **Identity / persona / model** | `Playbook#persona`, `config.default_model` | per-agent `persona` + `model` (agent may override the global default) |
| 2 | **Charter / Playbook** | one `config.playbook` | per-agent `playbook` (product brief, engagement signals, goals) |
| 3 | **Tool scope** | one `config.capabilities` registry | per-agent `capabilities` registry — least-privilege *per function* |
| 4 | **Authority envelope** | global boolean `draft_and_review` | per-agent **× per-action-class** authority (§10.5) |
| 5 | **Memory namespace** | `concierge_memories` keyed by Subject | keyed by **(agent_slug, Subject)**; optional shared namespace (§10.3) |
| 6 | **Kill switch** | *(none — only `weekly_review_enabled`)* | per-agent `enabled` flag checked at run start **and** at proposal execution; instant ops halt |

### How `agent` threads through the schema

Add a string **`agent_slug`** column to each per-agent table:

```
concierge_memories        concierge_conversations   concierge_routines
concierge_channel_deliveries  concierge_budget_ledgers  concierge_handoffs
concierge_outbox_items (→ concierge_agent_proposals, §10.6)
```

**Column, not an `agents` table + FK, for v1.** Agents are *config-defined code
artifacts*, not host-editable data: the slug is stable, there is no lifecycle to
model in the DB, and a column avoids a join on every scoped query plus a
config↔row sync problem. Introduce an `agents` registry table only if/when agents
become host-editable data (out of scope; note the seam). The slug is the same
kind of identifier `Subject#grain` already is.

### `SubjectScoped` → an agent-aware `Scope`

Today (`app/models/concerns/concierge/subject_scoped.rb`):

```ruby
scope :for_subject, ->(subject) { where(subject.key) }   # subject.key = {subject_type, subject_id}
```

Introduce a composite **`Concierge::Scope`** = an `(Agent, Subject)` pair whose
`#key` merges the agent dimension in:

```ruby
class Concierge::Scope
  def initialize(agent, subject) = (@agent, @subject = agent, subject)
  def key = { agent_slug: @agent.slug }.merge(@subject.key)
end
```

`SubjectScoped` gains `for_scope(scope)` (`where(scope.key)`) and
`find_by_scope(scope)`. This is the load-bearing isolation invariant, now
two-dimensional: **no query may cross an agent boundary or a subject boundary.**
The existing `for_subject` is retained as a back-compat shim that resolves the
default `:csm` agent during the migration window (§10.9), then is removed.

Everywhere a run, tool, store, or job currently receives a bare `subject`, it
receives a `scope` (or `(agent, subject)`) instead. `Run.reactive`/`.proactive`,
`ContextStore`, `Registry#tools_for`, `Governance`, `Outreach`, the sweep/review
jobs, and `Handoff.active_for` all move from subject-keyed to scope-keyed.

---

## 10.2 Memory / Rules split

**Adopt this regardless of OfferLab — it is a latent smell today.**

`Concierge::Memory` currently does double duty: episodic **relationship facts**
*and* **behavioral corrections**. The second arrives via `Learning.capture`
(`lib/concierge/learning.rb`), which writes an operator correction as a
`source: :human, pinned: true` **memory** row. That conflates "a fact about this
relationship" with "a generalized instruction about how to behave."

Split them:

- **Memory** = facts about a relationship, per (Agent × Subject). Episodic,
  recency-ranked, unversioned. Stays exactly as it is (plus the `agent_slug`
  key). *"This customer prefers email over in-app." "Renewal is in March."*
- **Rules** = **generalized, versioned, human-gated behavioral instructions with
  a lifecycle.** *"Never promise a delivery date without checking the shipping
  API." "For EU accounts, cite the GDPR data-processing addendum."*

### New `concierge_agent_rules` table

| column | purpose |
|--------|---------|
| `agent_slug`, `subject_type`, `subject_id` | scope keys; subject keys **nullable** so a rule can be agent-wide, segment-wide, or subject-specific |
| `segment` | optional named segment the rule applies to |
| `body` | the instruction text injected into the prompt |
| `state` | `proposed` → `active` → `deprecated` |
| `version` | bumped on edit; provenance snapshots pin `(id, version)` (§10.4) |
| `superseded_by_id` | the rule that replaced this one (consolidation trail) |
| `provenance` | source of the rule: handoff id, operator, originating run id, or "authored" |
| `predicate` | *optional* machine-checkable condition (e.g. a serialized matcher) |
| `enforcement` | `:advisory` (prompt-only) or `:guard` (checked at proposal time) |
| approver / timestamps | who moved it `proposed→active`, when deprecated, etc. |

### Lifecycle

- **Learning becomes an intake router.** `Learning.capture` inspects the takeover
  content and routes: a **relationship fact** → `ContextStore.remember` (as
  today); a **behavioral correction** → a rule in **`proposed`** state for a human
  gate. Routing is by explicit operator choice when available, heuristic
  otherwise (never silently promote to `active`).
- **Conflict-check-at-write-time.** On proposing/activating a rule, check it
  against active rules in the same scope; a contradiction surfaces for human
  resolution rather than silently coexisting.
- **Deprecation "dreaming" job.** A periodic job proposes consolidations and
  deprecations (redundant, stale, or superseded rules) — always as proposals for
  a human, never auto-applied.
- **Active-rule cap per scope.** A hard cap on `active` rules per scope. Hitting
  it **blocks** and raises a consolidation task — it never silently truncates the
  rule set. The cap is the forcing function that keeps rules generalized instead
  of accreting.

`enforcement: :guard` rules with a `predicate` can be evaluated against a
proposal at execution time (§10.6) — a bridge from "instruction the model should
follow" to "invariant the engine can check."

An `:advisory` rule is a suggestion, and should be understood as one: a live
model has been observed contradicting an advisory rule while sincerely citing it
as applied. If a rule *must* hold, it belongs in `:guard` with a predicate — see
§10.4, "Corollary: if a rule must hold, make it a guard."

---

## 10.3 Memory namespace (slot 5, detail)

Memory is keyed by **(agent_slug, Subject)** by default, so the disputes agent's
notes never leak into the CSM's prompt (and vice versa). Reserve one shared
namespace — `agent_slug = "_shared"` (or a `shared: true` flag) — for facts *about
the relationship* that every agent on that subject legitimately shares (e.g.
"this account is in the EU"). Default is **per-agent isolation**; sharing is
explicit opt-in, because cross-function contamination is the failure mode we are
trying to prevent. The existing two-tier grain (account-tier + subject-tier at
`:user` grain) composes under the agent dimension unchanged.

---

## 10.4 Per-run provenance snapshot

Concierge does not record *what went into a run's prompt*. Add it — it is small,
load-bearing for audit (the doc's **Air Canada** point: prove which policy was in
force when the agent said what it said), and it strengthens the CSM too.

Record, per run, onto a lightweight **run/provenance record**:

- the **memory ids** injected (`ContextStore.top_of_mind`),
- the **rule `(id, version)` pairs** injected,
- the **snapshot digest** (already computed for the change-gate),
- model, tokens, trigger, timestamp.

Runs are not persisted as rows today (`Concierge::Run` returns a `Result`). Add a
small `concierge_agent_runs` record (scope keys + the fields above), written at
run completion, linkable to the host `Chat`/`Message`. The structured decision
output the agent returns should carry **`rule_ids_applied`**, cross-checked
against the injected rule set (a rule the model *claims* to have applied that
wasn't in scope is a signal worth flagging).

This is the difference between "the agent probably followed policy" and "here is
the exact policy text, versioned, that was in the prompt for this decision."

### The pins are evidence. The citation is a claim.

Two things on the run row look alike and are not:

| field | written by | what it proves |
|-------|-----------|----------------|
| `rules` (the `(id, version)` pins) | **the engine**, from the rule set it just rendered into the prompt | what the agent **was told**. Evidence. |
| `rule_ids_applied` | **the model**, as a line in its own reply | what the model **says it did**. A claim. |

This distinction is load-bearing and was measured, not assumed. Three live turns
against `claude-sonnet-4-5` through the demo host (Dana / Acme / `csm`), with two
advisory rules injected and pinned on every turn:

- Asked something no rule bore on, the model cited nothing — `[]`. Correct.
- Asked *"when will scheduled exports ship? I need a date"*, against
  *"Never promise or imply a delivery date; point them at the status page
  instead"*, it declined to give a date, pointed at the status page, and cited
  that rule. Behaviour and self-report agreed.
- Asked *"is this automated? am I talking to a bot?"*, against a rule saying to
  *"keep the tone low-key and never mention automation"*, it answered **"yes —
  I'm an AI assistant helping out with support"** — and **cited that rule**.

The third turn is the whole point: `rule_ids_applied` can be confidently wrong
**in the compliance direction**. The row it produces is byte-identical to the
second turn's — same pins, a citation, `unknown_rule_ids` empty. Nothing the
engine records can tell the two apart, because the engine never sees the rule's
meaning, only its id coming back.

So: **a citation is not evidence a rule was followed, and no screen, card, or
export may present it as one.** The pins carry the audit story; the claim is
advisory metadata sitting next to them.

**We keep the claim** rather than dropping it, for three reasons, none of which
require it to be true:

1. It is the only signal that answers *"did the rule land in the model's
   attention at all?"* — a rule injected 200 times and never once cited is
   probably dead text, which is exactly the evidence `RuleDreamingJob` uses to
   *propose* (never perform) a retirement. That inference survives an unreliable
   claim: a false citation only **suppresses** a retirement proposal, and a
   missed citation only produces a proposal a human then rejects.
2. The cross-check against the injected set — "cited but never injected" — costs
   nothing and catches a genuinely different failure: an id the model invented,
   or a rule from a scope it should never have seen. Keep it regardless.
3. A wrong claim is itself a finding. Turn C is only legible *because* the model
   cited; a silent contradiction would have looked like an ordinary reply.

What we do **not** do is let it look like proof. The admin runs screen labels the
column as the agent's own unverified claim and says so in prose; the proposal
card and the Slack card say "claims", not "applied".

### Corollary: if a rule must hold, make it a guard

Turn C is the argument for `enforcement: :guard` (§10.2). An advisory rule is a
sentence in a prompt — a strong suggestion to a system that is free to weigh it
against everything else in its context, and that will sometimes decide against it
while sincerely believing it complied. That is not a bug to be prompt-engineered
away; it is what an advisory rule *is*.

The design position, stated plainly:

- **`:advisory` rules are suggestions.** Treat them as steering, not as
  constraints. Do not write a policy as advisory and then rely on it holding.
- **Anything that must actually bind belongs in `enforcement: :guard`** with a
  machine-checkable `predicate`, evaluated by the engine at proposal-execution
  time (§10.6), where the check short-circuits the model instead of asking it
  nicely. `Rules.guard_violations` already refuses the action; a guard cannot be
  talked out of it, and its verdict *is* evidence.
- The gap between the two is where the compliance risk lives. When an operator
  writes a rule whose violation would be a real incident, the honest answer is
  "that one needs a predicate," not "the model usually gets it right."

Guards cost more — someone has to express the condition in code — so most rules
will stay advisory, and that is fine. The requirement is only that nobody
mistakes which kind they have.

---

## 10.5 Authority envelope: `draft_and_review` → per-agent × per-action-class

Today authority is one global boolean: `config.draft_and_review`. It stages
**only** the outreach action, on or off, for the whole engine.

Replace it with a **per-agent authority envelope keyed by action class.** Three
levels:

| level | meaning | example |
|-------|---------|---------|
| `:autonomous` | execute within caps, no per-action human gate | CSM sending an in-app nudge |
| `:human_approval` | agent **proposes**; a human approves; the **engine executes** | updating a CRM record |
| `:human_execution` | agent **proposes**; a human approves **and executes** | issuing money (a refund) |

```ruby
c.agent :csm do
  authority do
    default :autonomous          # CSM stays autonomous-within-caps
  end
end

c.agent :disputes do
  authority do
    default          :human_approval
    action "money.refund", :human_execution   # money always gates to a human
  end
end
```

This **coexists with, and does not reverse,** the standing guidance that the CSM
is autonomous-within-caps (see memory `feedback_csm_agent_autonomy`). The CSM's
envelope is `:autonomous`; money/outward agents gate by default. Both are just
different envelopes on the same mechanism. The global `draft_and_review` boolean
becomes sugar for "the `:csm` agent's message action class is `:human_approval`"
during the migration, then is deprecated.

---

## 10.6 Generalize `OutboxItem` → `AgentProposal`

`Concierge::OutboxItem` (`concierge_outbox_items`: `body`, `channel`, `kind`,
state `pending → approved/discarded`) stages exactly one action class — outreach —
and only when `draft_and_review` is on. Reshape it into a general
**`AgentProposal`** over arbitrary action classes.

### `concierge_agent_proposals`

| column | purpose |
|--------|---------|
| `agent_slug`, `subject_type`, `subject_id` | scope keys |
| `action_class` | e.g. `"message.outreach"`, `"record.update"`, `"money.refund"` |
| `payload` | serialized arguments for the action (JSON) |
| `gate` | the authority level for this class (`:human_approval` / `:human_execution`), snapshotted at propose time |
| `state` | `proposed` → `approved` → `executed`; plus `rejected`, `expired` |
| `created_by` | the agent run / actor that proposed it |
| `approved_by` | the human who approved it |
| `idempotency_key` | dedupe key; execution is exactly-once against it |
| `precondition_digest` | hash of the state the proposal assumed; re-validated at execution |
| `rule_ids_applied` | provenance link (§10.4) |
| timestamps | `proposed_at`, `approved_at`, `executed_at`, `expires_at` |

### Rules of the object

- **Maker-checker:** `created_by ≠ approved_by`. The proposer can never approve
  its own proposal.
- **Execute-only-from-an-approved-record.** There is no "approve and execute in
  one call" path that bypasses the row; execution reads an `approved` row.
- **Precondition re-validation at execution time.** Between propose and execute,
  the world may have changed. Re-check `precondition_digest` (and any
  `enforcement: :guard` rule predicates from §10.2); a mismatch fails the
  execution rather than acting on stale assumptions.
- **Idempotency.** Execution is exactly-once per `idempotency_key`.

### Execution

`Concierge::Proposal::Execute` loads an approved row, re-validates preconditions +
guard rules + idempotency, then dispatches to the **executor registered for that
`action_class`**:

- `message.*` → built-in, via the existing `Outreach`/`Channel` delivery path.
- `record.*`, `money.*` → a **host-provided executor** (a callable the host
  registers per action class). This is where engine authority ends and host
  invariants begin (§10.8).

The current `Outreach#draft_to_outbox` path becomes "create an `AgentProposal`
with `action_class: "message.outreach"`," and existing pending outbox rows migrate
to that action class (§10.9).

---

## 10.7 Delivery and approval-intake are two seams

`ChannelBridge` (`Concierge::Channel::Base`) was built **outbound-only**: "never
raises, deliver + audit." That is correct and stays. But Slack-as-remote-control
is **bidirectional**, and the button-click → write-proposal → execute path is an
**inbound approval-intake** concern. Do **not** overload the channel abstraction
with interactivity.

Specify a **separate `Concierge::ApprovalIntake` seam** that any surface (Slack
Block Kit, Avo, in-app) can drive:

```ruby
Concierge::ApprovalIntake.approve(proposal, by: actor)
Concierge::ApprovalIntake.reject(proposal,  by: actor, reason:)
Concierge::ApprovalIntake.correct(proposal, by: actor, payload:)   # edit-then-approve
```

The seam authenticates the actor, enforces maker-checker (`by ≠ created_by`),
transitions the `AgentProposal`, and — on `approve` — invokes
`Proposal::Execute`. Surfaces are thin adapters: they authenticate the human and
call the seam; they hold no execution logic.

The two seams meet cleanly:

- **Outbound** (Channel): "here is a refund awaiting approval `[Approve][Reject]`"
  is a *delivery* — a normal channel send with a proposal reference in the payload.
- **Inbound** (ApprovalIntake): the click comes back through the intake seam.

One direction never has to know about the other's transport.

### A surface can have a deadline; an executor cannot promise to meet it

**The decision is synchronous. The execution belongs to whoever can afford to
wait for it.** Slack answers a `POST /concierge/slack/interactions` with an error
if the endpoint takes more than about three seconds. A host executor for
`record.*` or `money.*` — an external API, a payment provider — has no such
budget, and the actions with the slowest executors are exactly the ones this seam
exists to gate. Executing inside the interactivity request means an operator is
shown a failure for a decision that landed *and* executed: the row is right and
the human is told it is wrong, which is precisely the confusion §10.7 prevents
everywhere else.

So the handler order splits across the request boundary, and only there:

```
in the request:  1. verify the signature
                 2. write the decision to the AgentProposal row   (it *is* the record)
                 3. enqueue Concierge::ProposalExecutionJob
                 4. redraw the card: "approved, queued to be performed"
in the job:      5. Proposal::Execute
                 6. redraw the card with the outcome; whisper a refusal to the clicker
```

What this does **not** change:

- **Everything an operator is answerable for is still durable before the surface
  answers** — who approved, when, and what they approved. Only the doing moves.
- **`ApprovalIntake.approve(proposal, by:, execute: false)`** is the seam's
  existing opt-out, not a new one. A surface chooses whether it can wait.
- **The job holds no policy.** It re-enters `Proposal::Execute`, so all six
  refusals (§10.6) are re-checked *at the moment it runs*, which is later than
  before and therefore more current — an ops halt between the click and the job
  still stops the work.
- **At-most-once survives the queue.** Execute claims the row with a conditional
  `UPDATE`, so an ActiveJob retry performs the action once.
- **A deferred refusal is still a refusal.** "Approved but not performed" reaches
  the person who clicked, from the process that found it out. A surface that
  deferred execution and then reported success would be the original bug wearing
  a different hat.

Surfaces without a deadline keep executing inline — `/concierge/admin/proposals`
runs in a browser, which has no three-second ceiling, and its synchronous path is
what makes the ordering assertable end to end.

### The same opt-out on retry, and the state it has to leave behind

`ApprovalIntake.retry_execution(proposal, by:, execute: true)` takes the identical
seam, because retrying was the one path left that re-entered `Proposal::Execute`
synchronously with no way out. A surface that clears a failure from a Slack card
would hit exactly the wall Approve no longer hits.

Retry differs from approve in one way that matters. The synchronous half of an
approval *adds* to the row — who approved, when. The synchronous half of a retry
**erases**: clearing `execution_error`/`execution_failed_at` is what re-opens the
row to an executor (`Execute` claims only a row with `execution_failed_at IS
NULL`), and it destroys the only diagnostic an operator had. Between that clear
and the job, the row reads *approved, nothing recorded, nothing wrong* — the same
three columns as an approval nobody has attempted. If the enqueue fails, or the
queue is down, that window never closes.

So the queued retry is written to the row too — `execution_retry_queued_at` — and
`Proposal::Execute` clears it the moment it has any outcome to report, including
the refusals it does not otherwise write down (no executor, a halted agent). Two
surfaces read it: the admin queue's *"a retry was queued at …"*, and the Slack
card's `unexecuted_reason`. The card's `executing:` flag stays what it is — a
first execution is knowable only to the caller that queued it — but a retry is not
that, because it has already deleted something every other surface was showing.

---

## 10.8 Engine authority vs host invariants — the boundary

**The engine makes an action *proposable*; it does not enforce the host's
domain invariants.**

The doc's invariant — *"refunds only originate in OfferLab, from a human"* — is
enforced at the **host's `Orders::IssueRefund` seam, outside Concierge.** The
engine's authority model (envelope → proposal → maker-checker → idempotency →
precondition re-validation → dispatch to executor) governs *whether a proposal is
allowed to reach an executor*. The **host executor** re-checks its own invariants
independently.

- **Engine authority ends** at: "an `approved`, maker-checked, precondition-valid
  `AgentProposal` is dispatched to the registered executor."
- **Host invariants begin** inside that executor (`Orders::IssueRefund`), which
  re-verifies human origination, amount limits, order state, etc.

This is deliberately belt-and-suspenders: even a bug in the engine that dispatched
an unapproved money action would still hit the host's own human-origination guard
and be rejected. The engine is never the sole thing standing between an agent and
a refund.

---

## 10.9 Migration / back-compat plan (the CSM keeps working)

Expand/contract around the single new `agent_slug` dimension. No downtime, no
CSM behavior change.

**Config (`Concierge::Configuration`).** Keep the existing top-level blocks
(`account`, `playbook`, `capabilities`, `channels`, `draft_and_review`, `budget`,
`priority`, …) working by **folding them into an implicit `:csm` agent**: if a
host never calls `config.agent`, the top-level config *is* the `:csm` agent. Emit
a deprecation note steering hosts to `config.agent(:csm) { … }`. Two config styles
coexist through the deprecation window.

**Schema.** For each per-agent table:

1. Add **nullable** `agent_slug`.
2. Backfill `agent_slug = "csm"` for all existing rows.
3. Add the `agent_slug` component to the scoped indexes.
4. Flip `agent_slug` to `null: false`.

`SubjectScoped#for_subject` stays as a shim that scopes to the default agent
during the window; call sites migrate to `for_scope`; then the shim is removed.

**`OutboxItem` → `AgentProposal`.** Rename `concierge_outbox_items` →
`concierge_agent_proposals`; add `action_class` (default `"message.outreach"`),
`payload`, `idempotency_key`, `created_by`, `approved_by`, `executed_at`,
`precondition_digest`, `rule_ids_applied`. Existing `pending` rows map to
`action_class: "message.outreach"`, `state: proposed`. Keep an `OutboxItem`
constant aliased to `AgentProposal` for one release.

---

## 10.10 First implementation step: the spike (recommended)

**Prototype a second `config.agent` block in the dummy host app *before*
committing the schema change.** This is the doc's own open question, resolved
cheaply: if adding agent #2 is ugly, that is design feedback we want *before* we
migrate seven tables.

- Add a throwaway second agent to `test/dummy` (e.g. a toy `:billing` or
  `:ops` agent) over the same `Tenant` subjects, with its **own** persona, tool
  scope, and authority envelope.
- Drive the `Scope` object and the plural DSL by hand — no migration yet; the
  spike may fake `agent_slug` in memory.
- **Spike acceptance:**
  - two agents coexist over one `Subject`, each with an **isolated memory
    namespace**, **distinct tool scope**, and **distinct authority envelope**;
  - a proactive run for each does not cross-contaminate prompt or memory;
  - provenance (§10.4) records the correct `agent_slug`;
  - adding the second agent block *reads well* — the DSL is not awkward.
- Outputs that the spike decides: column-vs-FK for `agent_slug` (expected:
  column), the exact `Scope` shape, and whether the memory namespace default
  (per-agent isolation + `_shared`) feels right.

The spike is throwaway / behind a flag. It gates the schema work.

---

## 10.11 Downstream delta tasks and sequencing

The four deltas are already filed as backlog trackers referencing this design.
**They do not start until this design lands.** Sequence:

```
[0] Spike: 2nd config.agent in test/dummy         (§10.10 — GATE)
        │  proves the DSL + Scope + memory-namespace ergonomics
        ▼
[1] Pluralize agent definition + (Agent × Subject) schema   (§10.1, §10.9)
        │  the keystone — agent_slug on 7 tables, Scope, plural config,
        │  CSM→:csm back-compat. Everything below depends on it.
        ├───────────────┬───────────────────────────────┐
        ▼               ▼                                 │
[2] agent_rules      [3] AgentProposal                   │
    lifecycle on         (generalize OutboxItem →         │
    Learning +           arbitrary action classes;        │
    per-run              per-class gate; maker-checker;    │
    provenance           idempotency; precondition        │
    (§10.2, §10.4)       re-validation)  (§10.5, §10.6)    │
        │                     │                            │
        └─────────┬───────────┘                            │
                  ▼                                         │
[4] Slack approval-intake seam  ◄───────────────────────────┘
    (Block Kit approve/reject/correct → AgentProposal row → execute)
    (§10.7) — depends on [3]; [2]'s guard rules plug in at execution.
```

- **[1] first** — it is the dimension everything else is keyed by.
- **[2] and [3] parallelize** once [1] lands: rules are agent-scoped; proposals
  are agent-scoped and use the per-agent authority envelope. Neither blocks the
  other.
- **[4] last** — it needs `AgentProposal` rows to approve, and it wires
  guard-rule (`[2]`) checks into `Proposal::Execute`.

---

## 10.12 Risks & open questions

- **Isolation surface doubles.** The cross-account isolation test (§6) must
  become a cross-**(agent, account)** test: no query may escape *either*
  dimension. This is the load-bearing invariant of the whole phase — treat the
  test as a gate on task [1].
- **The isolation surface is not only account-to-account.** The engine's
  per-account endpoints sit on a second boundary: the customer and the staff
  serving them. `config.authorize_subject` answers "is this account yours", which
  a customer answers *yes* about their own; the handoff endpoints ask "are you
  staff, and is this account in your book" and so take their own hook,
  `config.authorize_operator`, which does **not** fall back to the first (task
  5005). A hook that answers one question must never be read as answering
  another — the same rule that keeps `authenticate_admin` separate from both.
- **`agent_slug` as data later.** If agents ever become host-editable data (not
  code), the column decision (§10.1) revisits as an `agents` table + FK. Note the
  seam; don't build it now.
- **Rule-cap ergonomics.** The active-rule cap (§10.2) must fail *loud and
  useful* (a consolidation task), never silent truncation. Validate the operator
  experience during task [2].
- **Provenance storage volume.** A `concierge_agent_runs` row per run adds write
  volume; confirm retention/rollup policy (§10.4) before shipping at scale.
- **OfferLab reconciliation.** Once this lands, `business-function-agents.md`
  §2.2 (six slots) and Phase 2 should be trimmed to a reference to §10 here, per
  Bruno's decision that Concierge's design is the source of truth.
