# Phase 10 review package

Phase 10 (`docs/design/phase-10-multi-agent.md`) landed across five merged PRs that ran
unattended. This is the human review gate. Nothing here is new code — it is QA, screenshots
of the running app, and an honest account of what matches the spec and what does not.

---

## What changed, and why it matters

1. Concierge used to *be* one agent. Its config was global: one `account`, one `playbook`, one
   `capabilities`, one `draft_and_review`.
2. Now identity is two-dimensional — **(Agent × Subject)**. An *Agent* is a host-declared config
   object; a *Subject* is still the account it acts on. Every row is keyed by the pair.
3. So one tenant can be served by several business functions at once. The dummy app runs two:
   `:csm` (Kit, warm, autonomous) and `:billing` (Bill, precise, gated).
4. Each agent carries six slots: persona/model, charter, tool scope, authority envelope, memory
   namespace, kill switch. An agent's tools are *its* tools; an off-scope tool is never registered.
5. Memory split in two. **Memory** = facts about a relationship, per (agent, account).
   **Rules** = generalized, versioned, human-gated instructions about behavior, with a lifecycle.
6. Rules never self-activate. An agent may *propose* one; only a person may promote it, the
   promotion is recorded, and a contradiction with a rule already in force blocks the approval.
7. Every run now writes a provenance row: which memories and which rule `(id, version)` pairs were
   in the prompt, the snapshot digest, model, tokens. Audit stops being "it probably followed policy."
8. `OutboxItem` (staged one action: an outbound message) generalized into **`AgentProposal`** over
   arbitrary action classes — `message.outreach`, `record.plan_change`, `money.refund`.
9. A proposal is maker-checked (the proposer can never approve it, and an agent can never approve at
   all), idempotent, and re-validated against the world at execution time — not at draft time.
10. Slack became a remote control over that queue, not a second source of truth: a button click
    writes the decision to the Postgres row through the same seam the admin form uses. If Slack is
    down, every decision is still available in `/concierge/admin/proposals`.

**Why it matters:** the engine stopped being a CSM with hardcoded authority and became a substrate
you can put a *money-touching* agent on, because the authority envelope, the gate, and the audit
trail are now first-class instead of one global boolean.

---

## Verification

`make verify` on current `main` (`ceea72b`): **green** — rubocop 212 files, no offenses; 441 runs,
1467 assertions, **0 failures, 0 errors, 0 skips**.

### The load-bearing invariant

`test/scope_isolation_test.rb` (§10.12) — I read it rather than trusting the pass. It is **not**
vacuous. It builds a real 2 agents × 2 accounts grid (`:csm`/`:billing` × Acme/Globex = 4 cells),
writes a distinguishable row into every cell, and then asserts each cell sees exactly its own —
across `Memory`, `Routine`, `Handoff`, `ChannelDelivery`, `Conversation`, `AgentProposal`,
`AgentRule`, `AgentRun` and `SlackCard`. Both dimensions are checked separately and by name
("no query escapes the agent dimension" / "…the account dimension"), so a bug that collapsed one
axis would fail loudly rather than pass by symmetry.

It also covers the awkward cases, which is what convinced me: the `_shared` namespace is readable by
both agents but owned by neither; rules have *no* shared namespace (an instruction that crosses
agents is the contamination the phase exists to prevent); an agent-wide rule crosses accounts but
never the agent boundary; the Slack daily card cap is counted per agent so one busy function cannot
mute another's approvals; and `for_subject` resolves the default agent rather than widening to all
of them.

**One gap:** every proposal in that test uses a per-cell `idempotency_key`, so keys never collide
across cells — which is exactly the hole the bug below falls through.

### Live checks against the running app

Driven through the browser and `rails runner` against the seeded dummy host, not in tests:

| Check | Result |
|---|---|
| Approve `record.plan_change` → engine executes | `:executed`; **Acme's `plan` really changed `pro` → `enterprise`** — the host executor ran |
| `money.refund` (`:human_execution`) approved | `:approved` and the engine **refused to perform it** — "the engine never performs this one — you do" |
| Precondition moved between propose and approve | `:precondition_failed`, digest mismatch recorded on the row, nothing executed |
| Guard rule matches the payload | `:blocked_by_rule` (rule #9), execution refused |
| The proposing agent tries to approve its own proposal | `GateError`: "agent:billing is an agent: an agent may propose an action but never approve one" |
| Same `idempotency_key` twice, same scope | one row, returned twice |
| Kill switch flipped after approval | `:agent_disabled` — halting a function stops its already-approved work |
| Gate refusals surface as a flash | yes, `.concierge-flash` renders them; no silent no-ops seen |

---

## Spec fidelity

| § | Spec item | Verdict | Notes |
|---|---|---|---|
| 10.1 | (Agent × Subject) identity; `Concierge::Scope` | **As specified** | `Scope#key` = `{agent_slug}` merged onto the subject pair; value semantics (`==`/`hash`) implemented, which the isolation grid depends on |
| 10.1 | `agent_slug` as a **column**, not an `agents` table + FK | **As specified** | Column on all per-agent tables; the seam is noted, not built |
| 10.1 | Six-slot agent definition | **As specified, with one deliberate divergence** | Slots 1–4 and 6 are settable. **Slot 5 (memory namespace) is deliberately *not* configurable** — the namespace *is* the slug (`Agent#memory_namespace`). Rationale in the code: a second settable identifier could only ever alias two agents onto one memory pool, the exact contamination §10.3 prevents. Good call; worth knowing it diverges from a literal reading of "six configurable slots" |
| 10.1 | Plural DSL: `config.agent(:slug)` sets, bare reads, `config.agents` | **As specified** | Mirrors the existing setter/reader pattern |
| 10.2 | Memory / Rules split; `concierge_agent_rules` | **As specified** | All spec'd columns present: `state`, `version`, `superseded_by_id`, `provenance`, `predicate`, `enforcement`, approver/timestamps. Plus a `concierge_agent_rule_revisions` table (not in the spec) so pinned `(id, version)` text is recoverable after an edit — an addition, and the right one |
| 10.2 | `Learning` becomes an intake router | **As specified** | Routes fact → `ContextStore.remember`, correction → rule in `proposed`. Never auto-promotes |
| 10.2 | Conflict-check-at-write-time | **As specified** | `Rules::ConflictCheck`; surfaced in the admin with an overlap score and an explicit "both rules belong — approve anyway" override |
| 10.2 | Deprecation "dreaming" job | **As specified** | `RuleDreamingJob`; proposes only |
| 10.2 | Active-rule cap that blocks rather than truncates | **As specified** | `Rules::CapReached` carries the cap *and* the consolidation candidates; default 12, `config.active_rule_cap` |
| 10.3 | Per-agent memory default, `_shared` opt-in | **As specified** | `Scope::SHARED = "_shared"`; writing is opt-in, reading is automatic |
| 10.4 | Per-run provenance with `rule_ids_applied` | **As specified** | `concierge_agent_runs` carries memory ids, rule pins, snapshot digest, model, tokens, trigger. The model's claimed `rule_ids_applied` is cross-checked against what was injected and the mismatch is surfaced as `unknown_rule_ids` — visible on the admin screen as "cited but never injected" |
| 10.5 | Per-agent × per-action-class authority | **As specified** | Three levels; `draft_and_review` folds in as sugar and only ever *tightens* (`Agent#level_for`) |
| 10.6 | `AgentProposal` over arbitrary action classes | **As specified** | Every spec'd column present |
| 10.6 | Maker-checker | **As specified** | Structural, not conventional: the `agent:` actor prefix can propose and can never approve |
| 10.6 | Execute-only-from-an-approved-record | **As specified** | Six ordered refusals in `Proposal::Execute`; no approve-and-execute path bypasses the row |
| 10.6 | Precondition re-validation | **As specified** | Verified live. Correctly reports "no check made" when the action class declared no precondition, rather than claiming a pass |
| 10.6 | Idempotency, exactly-once | **Diverged — see the bug below** | Execution is exactly-once (conditional `UPDATE` claim, at-most-once on crash, deliberate). *Proposing* dedupes on a **globally unscoped** key lookup |
| 10.7 | Delivery and approval-intake are two seams | **As specified** | `Channel::Base` has zero references to approval or interactivity. `ApprovalIntake` holds all policy; Slack and the admin are thin adapters that authenticate and call it |
| 10.7 | Outbound approval card is "a normal channel send" | **Diverged (defensible)** | Cards post through `Slack::Client` directly, not through a `Channel`. Reasonable — a Block Kit card must be *updated in place* after a decision, which the fire-and-forget `Channel#deliver` contract has no room for. But it does mean approval cards bypass the channel governance/audit path that ordinary outreach goes through |
| 10.7 | Queue visible and actionable in the admin | **As specified** | `/concierge/admin/proposals` approves, rejects (reason required), corrects, and records a human execution |
| 10.8 | Engine authority vs host invariants | **As specified** | Engine dispatches to a host-registered executor; `money.refund` deliberately has *no* registered executor in the dummy |
| 10.9 | CSM back-compat — a host that never calls `config.agent` | **As specified** | `ImplicitCsmAgent` reads its slots *through* to the Configuration at call time, so late config (an initializer setting `draft_and_review` after first read) is never stale. Covered by tests, and by `for_subject` resolving the default agent rather than widening |
| 10.9 | `OutboxItem` alias kept one release | **As specified** | `OutboxItem = AgentProposal`, documented as a read bridge |
| 10.12 | Provenance retention/rollup | **Partial** | `AgentRun.prune!(older_than:)` exists and the install template documents it, but there is no default policy or job — hosts must opt in. See follow-ups |

**Nothing in the spec is missing.** The two real divergences are slot 5 (deliberate, documented,
correct) and the Slack card transport (defensible, worth a conscious decision).

---

## The bug I found

Filed as **ty-5000**, not fixed here (this task writes no code).

**`AgentProposal` idempotency lookup is unscoped.** `Proposal.propose` dedupes with a global
`AgentProposal.find_by(idempotency_key:)`, and the unique index is on `idempotency_key` alone.
Every other read path in the phase goes through `for_scope`. This one does not.

Reproduced against the seeded app:

```
csm/Globex   propose(..., idempotency_key: "collide") -> #14 csm/5
billing/Acme propose(..., idempotency_key: "collide") -> #14 csm/5   # same row, different cell
```

Two failure modes: (1) a host that derives keys from a domain id — `"refund-#{invoice_id}"` —
without namespacing by agent gets **no proposal row and no error**, so an action a human should have
decided on never reaches the queue; (2) the caller receives another (agent, account)'s row, which is
the boundary crossing §10.12 calls load-bearing. Severity depends entirely on how hosts mint keys —
the engine's own callers are safe today.

---

## The five merged PRs

| Step | PR | What it did |
|---|---|---|
| 0 | [#5](https://github.com/bborn/concierge/pull/5) | Spike: a second `config.agent` block in `test/dummy` — proved the plural DSL, `Scope`, and memory-namespace ergonomics before migrating seven tables. **Gate: PASS** |
| 1 | [#6](https://github.com/bborn/concierge/pull/6) | The keystone: pluralized the agent definition, added `agent_slug` across the schema, introduced `Concierge::Scope`, and kept the CSM working as the implicit `:csm` agent |
| 2 | [#8](https://github.com/bborn/concierge/pull/8) | Split Memory from Rules: `agent_rules` with a proposed→active→deprecated lifecycle, conflict checks, the active-rule cap, and per-run provenance with `rule_ids_applied` |
| 3 | [#9](https://github.com/bborn/concierge/pull/9) | Generalized `OutboxItem` → `AgentProposal` over arbitrary action classes, with the per-class authority gate, maker-checker, idempotency and precondition re-validation |
| 4 | [#10](https://github.com/bborn/concierge/pull/10) | The Slack approval-intake seam: Block Kit approve/reject/correct → the same `ApprovalIntake` the admin form calls → `Proposal::Execute` |

(For context, not part of the chain: [#4](https://github.com/bborn/concierge/pull/4) landed the
design doc, [#7](https://github.com/bborn/concierge/pull/7) gave the admin screens their styling.)

---

## Screenshots

Real pages from the running dev server, captured with Playwright.

### Agents — two business functions over one tenant

Distinct personas, distinct tool scopes, distinct authority envelopes, distinct memory namespaces.
`:csm` is autonomous; `:billing` gates by default and sends money to `human_execution`.

![Agents](SCREENSHOT_BASE/01-agents.png)

### Memories — per-agent namespace separation

Look at `account#4`: `csm` rows and `billing` rows sit side by side and neither agent's prompt can
reach the other's. The single `_shared` row at the top is the explicit opt-in — a fact about the
relationship both agents legitimately read.

![Memories](SCREENSHOT_BASE/02-memories.png)

### The proposal / approval queue

Three actions staged for a human, each showing its gate, who proposed it, the state digest it
assumed, and where its Slack card went. Approve / Reject (reason required) / Correct-and-approve.

![Proposals](SCREENSHOT_BASE/03-proposals-queue.png)

### Rules — the human-gated behavioral layer

Two proposals awaiting a tap. The first is flagged as a **contradiction of rule #7** (0.56 overlap)
and cannot be approved until a human resolves it or explicitly checks "both rules belong." Below,
four rules in force — agent-wide, account-specific, and one `guard` rule that is enforced in code.

![Rules](SCREENSHOT_BASE/04-rules.png)

### Run provenance

What each turn was actually told: the memories injected, the rules pinned at `(id, version)`, the
snapshot digest, and — the top row — a run where the model cited rule `9999` that was never in its
prompt, flagged as **"cited but never injected"** rather than discarded.

![Run provenance](SCREENSHOT_BASE/05-runs-provenance.png)

### Routines and deliveries — both keyed by the pair

![Routines](SCREENSHOT_BASE/06-routines.png)

![Deliveries](SCREENSHOT_BASE/07-deliveries.png)

### Slack approval intake

One channel per agent, a per-agent daily card cap (so one busy function cannot make a channel
unreadable), and the two endpoints. Note the framing: *Slack is the remote control; Postgres is the
record.* Suppressed cards are still decidable in the admin queue.

![Slack](SCREENSHOT_BASE/08-slack.png)

### Approving a proposal actually executes it

Flash confirms `Proposal #6 executed.`, the row moves to Decided as `executed`, and Acme's plan
really changed from `pro` to `enterprise` — the host executor ran.

![Approved and executed](SCREENSHOT_BASE/09-proposal-approved-executed.png)

### The `human_execution` gate refuses to act

Approving the refund records the decision and stops. "The engine never performs this one — you do,"
with an *I performed this* button for the human to record it afterwards.

![Human execution gate](SCREENSHOT_BASE/10-human-execution-gate.png)

---

## Click-through script

The dev server is running at **http://localhost:3000**. No login — the dummy host has no auth;
every admin screen is open. Start at **http://localhost:3000/concierge/admin/agents**.

It works fully offline: with `ANTHROPIC_API_KEY` unset the engine uses a scripted chat. To reset to
the state below at any point: `cd test/dummy && bin/rails db:seed`.

1. **See the two agents.** `/concierge/admin/agents`.
   *Expect:* two blocks — `csm` (Kit, 5 tools, `default autonomous`, "nothing staged for a human")
   and `billing` (Bill, 2 tools, `default human_approval · money.refund human_execution`,
   "3 actions awaiting approval"). Different personas, different tool scopes, different authority.
   At the bottom, the `_shared` namespace holding 1 memory.

2. **Confirm one agent cannot see the other's memory.** `/concierge/admin/memories`.
   *Expect:* `account#4` (Acme) has `csm` rows about goals and the champion, and separate `billing`
   rows about the card on file and invoice #4471. Neither agent's prompt contains the other's rows —
   the `AGENT` column *is* the namespace. The one `_shared` row ("Acme is an EU entity") is the
   deliberate exception, and it is in neither agent's own space.

3. **See what the agent was actually told.** `/concierge/admin/runs`.
   *Expect:* six `csm`/`account#4` runs, each listing the memories and the rules injected, pinned at
   `v1`. **`RULES CITED` is `rule_ids_applied`** — the model's own claim. The top row (`billing`)
   cites rule `9999` that was never injected and is flagged **"cited but never injected: 9999"`.
   That flag is the point: a claim the engine can't corroborate is surfaced, not trusted.

4. **See the gate.** `/concierge/admin/proposals`.
   *Expect:* three staged actions. `#5` is an outbound message from the gated `billing` agent;
   `#6` a `record.plan_change`; `#7` a `money.refund`. Each shows its gate, `PROPOSED BY
   agent:billing`, and a state digest it assumed. Note `#7` reads **"human execution — the engine
   will not perform this."**

5. **Approve a record change and watch it execute.** Click **Approve** on `#6`
   (`record.plan_change`, Acme, pro → enterprise).
   *Expect:* a green flash **"Proposal #6 executed."**, and `#6` drops into **Decided** as
   `executed`, decided by `operator@acme.test`. The host executor really ran — Acme's plan is now
   `enterprise`. Reload `/concierge/admin/agents`: billing is down to 2 actions awaiting approval.

6. **Watch money refuse to execute.** Click **Approve** on `#7` (`money.refund`).
   *Expect:* flash **"Proposal #7 approved."** — *approved*, not executed. It moves to
   **"Approved — not performed yet"** with the reason **"the engine never performs this one — you
   do"** and an *I performed this* button. This is §10.8: the engine's authority ends at "an
   approved, maker-checked, precondition-valid proposal reached an executor," and money has none.

7. **Watch the world moving underneath a proposal.** Before approving `#5`, open a console
   (`cd test/dummy && bin/rails console`) and change the state it assumed — or simply take my word
   from the verification table above, where a plan change whose precondition moved returned
   `:precondition_failed` and refused, recording the digest mismatch on the row rather than acting
   on a stale assumption.

8. **See a rule blocked for contradicting one in force.** `/concierge/admin/rules`.
   *Expect:* rule `#12` ("Always promise a delivery date") flagged **"Resolve before approving"**
   against rule `#7` ("Never promise or imply a delivery date"), with a 0.56 overlap score. It
   cannot be approved without ticking "both rules belong — approve anyway." Note both proposals were
   drafted by an agent (`agent:csm`, `agent:billing`) from a **verbatim human correction**, stored
   in the provenance — this is the Memory/Rules split working: a correction became a *rule* proposal,
   not a silent memory row.

9. **Approve a rule and watch the promotion get recorded.** Click **Approve — make active** on
   rule `#11` ("Always attach the invoice PDF to a billing email").
   *Expect:* it moves into **Active**, `APPROVED BY operator@acme.test`, and the cap line reads
   `2 of 12 allowed` for billing. Nothing activates itself — an agent may propose, only a person promotes.

10. **See Slack as a remote control, not a second record.** `/concierge/admin/slack`.
    *Expect:* one channel per agent, `billing` at 2/2 cards today with 2 suppressed by the cap. The
    suppressed ones are **still in the admin queue** and decidable there — an outage costs
    convenience, not authority. Click a proposal link to land back on the same row you'd approve
    from Slack.

11. **Prove the isolation is real, not cosmetic.** `cd test/dummy && bin/rails console`:
    ```ruby
    acme    = Concierge.config.account.find_subject(Tenant.find_by(name: "Acme Corp").id)
    csm     = Concierge::Scope.new(Concierge.config.agent(:csm), acme)
    billing = Concierge::Scope.new(Concierge.config.agent(:billing), acme)

    Concierge::ContextStore.new.top_of_mind(csm).map(&:body)
    Concierge::ContextStore.new.top_of_mind(billing).map(&:body)
    ```
    *Expect:* two disjoint lists over the same account — except for the one `_shared` EU-entity fact,
    which appears in both. That is the whole phase in two lines.

---

## What I could not verify

- **A real LLM in the loop.** Every run here used the scripted `FakeChat`. The prompt *assembly* is
  verified (provenance rows show exactly which memories and rule versions went in), but not whether
  a real model honours an injected rule, nor whether `rule_ids_applied` citations come back
  well-formed from a live provider. The engine treats a bad citation as a flag rather than a crash,
  which is the right posture, but the flag has never fired against a real model.
- **A real Slack workspace.** Step 4's seam is exercised through a fake transport. Signature
  verification, the URL handshake, modal submission and card-update-in-place are unit-tested against
  recorded payloads; none of it has touched Slack's actual API. `actor_for` mapping a Slack user to a
  host identity is the piece I'd most want to see against a real workspace.
- **Concurrency on `Proposal::Execute`.** The exactly-once claim is a conditional `UPDATE` that only
  one caller can win, which is the right shape, but I did not run concurrent approvals against a real
  Postgres to confirm it under contention. (The dummy runs SQLite.)
- **Migration against real data.** §10.9's expand/contract (add nullable `agent_slug`, backfill
  `"csm"`, index, flip to `null: false`) is correct on a fresh dummy schema. No production-shaped
  table with existing `concierge_outbox_items` rows has been migrated.
- **Performance at scale.** No load testing. A provenance row per run is real write volume (below).
- **The OfferLab side.** `business-function-agents.md` lives in another repo; I could not check
  whether its §2.2 has been trimmed to a reference.

---

## Open risks and follow-ups

1. **The unscoped idempotency key (ty-5000).** Highest-value item here. The fix is small — scope the
   lookup to the pair and make the unique index composite — and it closes the one hole in an
   otherwise excellent isolation grid. Worth adding the colliding-key case to
   `scope_isolation_test.rb` so the grid actually covers it.
2. **Provenance storage volume (§10.12).** A row per run. `AgentRun.prune!(older_than:)` exists and
   the install template documents it, but there is **no default retention policy and no job** —
   a host that never reads that comment accumulates rows forever. Consider a default in `SweepJob`,
   or at minimum a startup warning past some row count.
3. **Rule-cap ergonomics (§10.12).** The cap blocks loudly and `CapReached` carries the consolidation
   candidates, which is the right mechanism. But I could not exercise the operator experience *at*
   the cap — the seed has 3 of 12 active for `csm`. Somebody should seed a scope to 12 and walk the
   consolidation flow before a real host hits it cold.
4. **`agent_slug` as data (§10.12).** Still a column, still correct for v1. The seam is noted in the
   code. Revisit only when agents become host-editable; nothing to do now.
5. **OfferLab reconciliation (§10.12).** `business-function-agents.md` §2.2 and its Phase 2 should be
   trimmed to a reference to §10 here, per the decision that Concierge's design is the source of
   truth. Not done — different repo, outside this chain.
6. **Approval cards bypass the channel path.** Slack cards post through `Slack::Client` directly, so
   they do not appear in the delivery audit log and are not subject to channel governance. Defensible
   (a card must be updated in place), but it means "everything the engine sent" is now two logs, not
   one. Worth a conscious ruling.
7. **Slot 5 is not configurable.** The memory namespace is the slug, by design. If a host ever
   legitimately needs two agents sharing one memory pool, they will have to use `_shared` per fact
   rather than aliasing. I think that is right; flagging it so the constraint is chosen rather than
   discovered.
8. **`draft_and_review` and `OutboxItem` are both deprecation-window scaffolding.** Both work today.
   Somebody should decide when the window closes, because `Agent#level_for`'s "only ever tightens"
   special case and the `OutboxItem` alias are both carrying complexity that is meant to be temporary.
