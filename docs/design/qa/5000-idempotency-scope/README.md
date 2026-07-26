# QA — scoping the proposal idempotency key to the (Agent × Subject) pair

The defect (ty-5000, filed out of the phase-10 step-5 review package): `Proposal.propose`
deduped on `idempotency_key` with a **global** `AgentProposal.find_by`, backed by a
globally-unique index on that column alone. A key minted in one cell matched a row in
another, so the second caller's action was never staged and it was handed a proposal
belonging to a different agent *and* a different account.

## Reproduced first, against the seeded dummy app

`cd test/dummy && bin/rails db:prepare && bin/rails db:seed`, on `main` (`c0a1e02`), then a
`bin/rails runner` script proposing the *same* `idempotency_key` from two cells. `:billing`
is the only gated agent in this host, so the reproduction below crosses the **account**
dimension; the agent dimension is covered in the test suite, where both agents gate.

```
# before — main
billing/Acme    -> #5  billing/1  payload={"to"=>"enterprise", "note"=>"billing/Acme"}
billing/Globex  -> #5  billing/1  payload={"to"=>"enterprise", "note"=>"billing/Acme"}   # <- Acme's row
rows with that key: 1
billing/Acme sees 1 of them
billing/Globex sees 0 of them
```

```
# after — this branch
billing/Acme    -> #6  billing/1  payload={"to"=>"enterprise", "note"=>"billing/Acme"}
billing/Globex  -> #7  billing/2  payload={"to"=>"enterprise", "note"=>"billing/Globex"}
rows with that key: 2
billing/Acme sees 1 of them
billing/Globex sees 1 of them
```

| # | Screenshot | What it shows |
|---|------------|---------------|
| 01 | `01-before-one-row.png` | `/concierge/admin/proposals` on `main`: **Awaiting a human (4)**. Globex's plan change is simply not there — one `record.plan_change` for `billing · account#1`, note `billing/Acme`. A human was never going to see the other request. |
| 02 | `02-after-two-rows.png` | The same page on this branch: **Awaiting a human (5)** — `#6 billing · account#1` (`note: billing/Acme`) and `#7 billing · account#2` (`note: billing/Globex`), both from the identical key. |

Both taken with the Playwright MCP browser against a genuinely running server
(`bin/rails server -p 3111`), against the seeded dev database, viewport 1280×900, full page.

## The fix

- `Concierge::Proposal.propose` dedupes through `AgentProposal.for_scope(scope)` — the same
  door every other read in the phase goes through.
- The unique index moves from `idempotency_key` to
  `(agent_slug, subject_type, subject_id, idempotency_key)`
  (`db/migrate/20260101000016_scope_proposal_idempotency_to_the_pair.rb`), and the model's
  uniqueness validation moves with it. Exactly-once *execution* (§10.6) never rested on the
  global index — `Proposal::Execute` claims the row with a conditional `UPDATE` — so nothing
  about execution changes.
- The migration's `down` refuses with `ActiveRecord::IrreversibleMigration` (naming the
  offending keys) when keys are by then legitimately reused across pairs, rather than
  failing on a unique-index violation or dropping rows. Verified by hand: inserted two rows
  sharing a key in two scopes, ran `db:migrate:down`, got the refusal and an untouched index.

## Tests

`make verify` — rubocop 240 files, no offenses; **507 runs, 1786 assertions, 0 failures,
0 errors, 0 skips** (503 runs on `main`, so 4 new tests).

Four new cases, three of them in the load-bearing suite rather than beside it:

- `test/scope_isolation_test.rb` — "one idempotency key proposed from every cell stages four
  proposals, not one": the full 2×2 grid proposes `"plan-change-4471"`, and each cell must
  end up with its own row and its own payload.
- `test/scope_isolation_test.rb` — "idempotency still holds inside a cell": the same key
  twice in one cell is still one row. The fix narrows the lookup; it does not remove it.
- `test/schema_test.rb` — the unique index is `(agent_slug, subject_type, subject_id,
  idempotency_key)`, mirroring the existing conversation-index assertion.
- `test/schema_test.rb` — the uniqueness validation moved with it: another agent over the
  same subject may reuse a key; the same agent may not.

### Mutation testing (each mutation applied, suite run, then reverted)

| Mutation | Red |
|----------|-----|
| A. restore the unscoped `AgentProposal.find_by(idempotency_key:)` in `propose` | **1** — the grid test (expected 4 rows, got 1) |
| B. restore `validates :idempotency_key, uniqueness: true` (table-wide) | **2** — the schema validation test, and the grid test (`create!` raises) |
| C. restore the global unique index (migration removed, schema reloaded) | **2** — the schema index test, and the grid test (`RecordNotUnique`) |

### One thing found along the way

The existing isolation case "handoffs, conversations, deliveries, proposals, rules and runs
all carry the pair" created its `SlackCard` with a hard-coded `agent_proposal_id: 1`, so it
depended on `concierge_agent_proposals` starting from an empty autoincrement sequence. It
errors (`Proposal must exist`) against any test database whose sequence has moved — I hit it
after inserting rows by hand to exercise the migration's `down` guard. Changed to reference
the proposal the same test just created. Not masking a failure: the sequence has nothing to
do with what that test asserts, and the assertions are untouched.

## What I could not verify

- **A real model.** `ANTHROPIC_API_KEY` was unset for the server run, so the dummy host used
  `Dummy::ScriptedChat`. Nothing in this change touches the model path — proposals here were
  staged by a `bin/rails runner` script calling `Proposal.propose` directly, exactly as an
  agent run's tool would — but no live LLM turn was exercised.
- **The agent dimension in the running app.** The dummy host's `:csm` is `default :autonomous`,
  so it cannot stage a proposal at all and the browser reproduction necessarily crosses only
  the account boundary. The agent boundary is covered in `scope_isolation_test.rb`, where both
  agents gate.
- **Postgres.** The dummy host is SQLite. The index change is ordinary DDL and the `down`
  guard uses plain SQL, but it has not been run against Postgres or MySQL. The new index name
  (`index_concierge_agent_proposals_on_scope_and_idempotency_key`, 59 chars) is inside
  Postgres's 63-character identifier limit.
- **Existing production data.** No host has run this. The narrower index is always satisfiable
  from the wider one — every key that was globally distinct is distinct within its pair — so
  `up` cannot fail on existing rows, but that is an argument, not an observation.
