# Phase 10, step 0 — spike findings (the GATE)

> **Verdict: PASS.** All four §10.10 acceptance criteria hold. Step 1 (#4982) may
> proceed with the schema change.
>
> This document is the *input* to steps 1–4. The three decisions in §A are
> settled — downstream steps implement them and do not re-open them.

Prototype lives under `lib/concierge/spike/`, is inert unless a host sets
`config.multi_agent_spike`, migrates nothing, and is **deleted by step 1**.

---

## A. The three decisions §10.10 asked this spike to make

### A1. `agent_slug` — **column**, not an `agents` table + FK

**Decision: a string `agent_slug` column on each per-agent table.** As §10.1
expected. The spike did not find anything that argues for a registry table:

- Every agent attribute the runtime reads — persona, model, playbook,
  capabilities, authority, kill switch — came from *config*, never from a row.
  Nothing wanted to be joined to.
- The slug is used as a **query key on every read** (`Memory.for_scope`,
  `Routine.for_scope`, `Conversation.find_by_scope`, `Handoff.active.for_scope`).
  A join on the hot path for a value that is a compile-time constant is pure cost.
- A table would introduce a config↔row sync problem with no owner: what happens
  when a host renames or removes an agent block that has rows pointing at it?
  With a column, orphaned rows are inert data with a slug nobody serves — a
  reporting question, not a referential-integrity failure.
- The kill switch (slot 6) is the one thing that looked like it might want to be
  data ("halt billing right now without a deploy"). It does not: `enabled` is
  read at run start from config, and an ops halt that needs to survive a deploy
  is a config change, which is what a code-defined agent should be. If that
  changes, it wants its own tiny `agent_states` table, not a full registry.

**Seam to keep open (do not build now):** if agents ever become host-*editable*
data, this revisits as an `agents` table + FK. Nothing in the step-1 schema
should make that harder than "add a table, add a FK, keep the slug as the
natural key."

### A2. The `Scope` shape

**Decision: exactly the §10.1 shape, with two additions.**

```ruby
class Concierge::Scope
  SHARED = "_shared"                       # the one reserved namespace

  def initialize(agent, subject) = (@agent, @subject = agent, subject)

  def agent_slug = @agent.slug.to_s
  def key        = { agent_slug: agent_slug }.merge(@subject.key)
  def shared_key = { agent_slug: SHARED }.merge(@subject.key)

  # value semantics — two Scopes are equal iff agent AND subject match
  def ==(other) = other.is_a?(Scope) && other.agent_slug == agent_slug &&
                  other.subject == @subject
  def hash      = [ agent_slug, @subject.grain, @subject.id ].hash
end
```

Notes for step 1:

1. **`#shared_key` belongs on Scope, not on the store.** Every table that could
   ever hold a shared row asks the same question; putting the answer next to
   `#key` keeps one definition of what "`_shared`" means.
2. **Value semantics are load-bearing.** The isolation tests key a 2×2 grid by
   Scope; without `==`/`hash` the grid silently collapses. Ship them.
3. **`SubjectScoped` gains `for_scope` / `find_by_scope`, and they are
   duck-typed on `#key`.** That is what makes migration incremental: a call site
   that has no agent dimension yet can pass a bare `Subject` to `for_scope` and
   get today's behaviour. `for_subject` stays as the §10.9 shim and is removed
   at the end of the window. (Both are already merged — see
   `app/models/concerns/concierge/subject_scoped.rb`.)
4. **Tools bind to a Scope, not a Subject.** `NativeTool` gained `scope:` and
   `store:` (both default nil → today's behaviour) and `#scope`, which returns
   the Scope when bound and the Subject otherwise. This is what stops a tool call
   mid-run from writing outside its agent's namespace, and it means **one tool
   class works under both runtimes** — no forked tool hierarchy. Already merged.
5. **`Snapshot.for(subject, playbook:)` stays subject-keyed** and takes the
   agent's playbook. An agent does not get a different *account*; it gets a
   different *view* of one. Its digest therefore differs per agent, which is what
   makes provenance meaningful.

**Not every table gains the dimension.** `concierge_outreach_preferences` is the
customer's preference about being contacted at all — it belongs to the subject,
not to any agent, and stays subject-keyed. §10.1's list of seven is right;
step 1 should not widen it.

### A3. Memory namespace default — **yes, per-agent isolation + `_shared` is right**

Confirmed, with the read/write asymmetry made explicit (§10.3 left it ambiguous):

| | rule |
|---|---|
| **write** | the agent's own namespace. Sharing is an explicit opt-in: `remember(scope, …, shared: true)`. |
| **read** | the agent's own namespace **+ `_shared`**. |

Reads must fold in `_shared` automatically or the shared namespace is
write-only and therefore pointless. The isolation that actually matters — and
that the tests assert — is that agent A never reads agent B's *private* notes.

Two further findings:

- **A configurable `memory_namespace` was prototyped and deliberately removed.**
  The namespace **is** the slug. A second, settable identifier is only ever a way
  to alias two agents onto one memory pool, which is the exact cross-function
  contamination §10.3 exists to prevent. Slot 5 is therefore not a config knob:
  it is a consequence of the slug. Step 1 should not add one.
- **`recall` is narrower than `top_of_mind` on purpose.** `recall` (the tool the
  agent calls) returns the agent's own namespace only — it is how an agent
  inspects what *it* knows. `top_of_mind` (prompt assembly) folds in `_shared`.

---

## B. Acceptance — evidence

| §10.10 criterion | Verdict | Evidence |
|---|---|---|
| Two agents coexist over one Subject with isolated memory, distinct tool scope, distinct authority | **PASS** | `test/spike/scope_isolation_test.rb`, `test/spike/agent_dsl_test.rb` |
| A proactive run for each does not cross-contaminate prompt or memory | **PASS** | `test/spike/multi_agent_run_test.rb` |
| Provenance records the correct `agent_slug` | **PASS** | `multi_agent_run_test.rb`, plus the live provenance table on `/concierge/admin/spike` |
| Adding the second agent block reads well | **PASS** | see §C |

The 2×2 grid (2 agents × 2 accounts) plus `_shared` is asserted cell by cell.
Deliberately breaking `Scope#key` so it drops the agent dimension turns **12** of
those tests red; un-binding tools from their scope turns **3** red. The tests
detect the leak they claim to detect.

---

## C. Does agent #2 read well? Yes — with three notes

The dummy host's second agent, verbatim from
`test/dummy/config/initializers/concierge.rb`:

```ruby
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
```

Three things the spike changed to get here, which step 1 should keep:

1. **`persona` is hoisted to the top of the agent block** (it delegates to the
   agent's Playbook, where it has always lived). Two agent blocks then read as
   two *people* rather than two config hashes. This is most of why it reads well.
2. **The six slots read as six lines, not six sections.** `model` and `enabled`
   are one-liners that are simply absent when defaulted — the billing block above
   never mentions either.
3. **Authority is a block, not a hash.** `default :human_approval` +
   `action "money.refund", :human_execution` is the same setter/reader rule as
   everywhere else, and an unknown level raises at *configure* time
   (`Concierge::Error`), not at run time.

**Back-compat reads well too, and is cheap.** A host that never calls
`config.agent` folds into an implicit `:csm` agent that returns *the same*
Playbook and Registry objects the top-level blocks return — not copies, so
nothing can drift. `draft_and_review: true` maps to
`:human_approval` on the `message.outreach` action class. Both are already
implemented and tested here; step 1 should port them as-is.

---

## D. What the spike surfaced that §10 does not say

These are new inputs for steps 1–4, not re-litigation.

1. **`concierge_conversations` is a contamination vector, and the fix is on the
   §10.1 list already.** Without the agent dimension, two agents over one subject
   share one persistent `Chat` — every prior turn of the CSM's thread is in the
   billing agent's context window. Keying conversations by scope fixes it, and
   the existing `subject_id`-unique-per-`subject_type` validation becomes
   unique-per-`(agent_slug, subject_type)`. **Step 1 must not skip this table.**
2. **Handoff becomes per-(agent, subject), and that is the correct behaviour.**
   A human taking over the billing thread should not silence the CSM. Asserted in
   `multi_agent_run_test.rb`. Worth calling out because it is a *behaviour*
   change riding along with a *key* change.
3. **`Run` needs about six substitutions, all mechanical** — `@subject` → `@scope`,
   `@config.playbook` → `agent.playbook`, `@config.capabilities` →
   `agent.capabilities`, `@config.default_model` → `agent.model || …`,
   `ContextStore` → the namespaced store, plus the kill-switch and provenance
   writes. Compare `lib/concierge/spike/run.rb` against `lib/concierge/run.rb`.
   The spike keeps them as separate classes only so it stays deletable.
4. **Provenance wants the snapshot digest per agent.** Two agents with different
   engagement signals produce different digests over the same account, which is
   exactly what makes "what state was the agent looking at" answerable. The
   `concierge_agent_runs` row should store it (§10.4 already says so — this
   confirms it is not redundant with the change-gate's digest).
5. **The implicit-`:csm` agent is memoized**, so a host that mutates
   `draft_and_review` *after* first reading `config.agent(:csm)` gets a stale
   envelope. Harmless in an initializer; step 1 should either build it eagerly at
   the end of `configure` or drop the memo once agents are always explicit.

---

## E. Pre-existing bug found while running the app (not caused by this work)

The dummy host app's documented offline mode was **broken on `main`**:
`Concierge::Run` raised `RubyLLM::ConfigurationError` when `ANTHROPIC_API_KEY`
was unset, because RubyLLM's `Models.resolve` instantiates the provider — which
calls `ensure_configured!` — *before* it honours `assume_model_exists`. Swapping
in a scripted chat is not enough; creating the `Chat` record itself needs a
configured provider.

Fixed in `test/dummy/config/initializers/ruby_llm.rb` with a placeholder key
(nothing can reach the network on that path: with no real key the chat object is
`Dummy::ScriptedChat`). This mirrors what `test/test_helper.rb` already does, and
for the same reason. It is a dummy-app fix only — no engine behaviour changed.
It deserves its own look: a real host with no credentials hits the same wall.
