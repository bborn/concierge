# QA — Retry gets the same opt-out Approve has, and says what it erased

The defect (ty-5007, filed while splitting Slack's Approve off the interactivity request in
#4999): `ApprovalIntake.retry_execution(proposal, by:)` cleared the recorded failure and
called `Proposal::Execute` **inline**, with no way to defer. After #4999 it was the one path
left that re-entered the executor synchronously, so the first host to put a Retry button on a
Slack card would hit exactly the three-second wall Approve no longer hits.

## Reproduced first, against the running dummy host

`cd test/dummy && bin/rails db:prepare && bin/rails db:seed`, then `bin/rails runner` with
`SLOW_EXECUTOR=4` — the knob #4999 added to the dummy's `record.plan_change` executor so a
slow host executor can be seen by hand. Nothing stubbed; the real seam, the real executor.

**Before — `main` (`c9012bc`):**

```
proposal #8 billing record.plan_change {"from"=>"free", "to"=>"pro", ...}
retry_execution parameters: [[:req, :proposal], [:keyreq, :by]]
execute: false -> REFUSED: ArgumentError: unknown keyword: :execute
retry_execution(by:) -> :executed in 4.022s (Slack's interactivity budget is ~3s)
after:  state=executed executed_at=2026-07-26 05:20:59 UTC
```

There is no seam, and the only call there is takes 4.022 seconds.

**After — this branch, same executor, same proposal shape:**

```
retry_execution parameters: [[:req, :proposal], [:keyreq, :by], [:key, :execute]]

retry_execution(execute: false) -> :approved in 0.000s   (Slack's budget is ~3s)
  row:  state=approved error=nil failed_at=nil
        execution_retry_queued_at=2026-07-26 05:26:44 UTC
  card: :hourglass: *Approved* by dana@acme.test … — a retry is queued — this card updates when it is performed
  plan: enterprise   (nothing performed yet)

ProposalExecutionJob     -> :executed in 4.036s
  row:  state=executed execution_retry_queued_at=nil
  plan: pro

retry_execution(by:)     -> :executed in 4.017s   (the admin default, still inline)
  plan: pro
```

**4.022s → 0.000s** in the request; the 4 seconds moved to the job. The admin's inline default
is untouched at 4.017s — a browser has no three-second ceiling, and the operator who clicked
Retry is the person who should watch it succeed or fail.

The job takes no `retry_failed:` of its own and needs none: the failure that would have refused
it (`:execution_previously_failed`) was cleared synchronously, which is the whole reason that
write stays in the request.

## The part the ticket warned about: clearing erases

An approval's synchronous half *adds* to the row — who, when. A retry's synchronous half
**deletes**: clearing `execution_error`/`execution_failed_at` is what re-opens the row to an
executor (`Execute` claims only where `execution_failed_at IS NULL`), and it destroys the only
diagnostic the operator had. Between the clear and the job the row reads *approved, no error,
nothing failed* — identical to an approval nobody has attempted. If the enqueue fails, that
window never closes.

So the queued retry is written to the row too (`execution_retry_queued_at`), and
`Proposal::Execute` clears it the moment it has any outcome — including the refusals it does
not otherwise write down, like a missing executor or a halted agent.

| # | Screenshot | What it shows |
|---|------------|---------------|
| 01 | `01-queue-a-queued-retry-next-to-an-untouched-failure.png` | `/concierge/admin/proposals`, **Approved — not performed yet (2)**. #2 still carries `Net::ReadTimeout: the billing API did not answer`; #4's retry was queued by a deferring surface and the queue says so: *"a retry was queued at 2026-07-26 05:27:13 UTC — it clears when the executor reports back"*. Both keep **Retry execution**, because a queue that never runs is exactly when an operator needs the browser's inline path back. |
| 02 | `02-the-same-row-without-the-stamp-reads-as-nothing-wrong.png` | The same running server, the same row, with `execution_retry_queued_at` nulled — what a clear-without-a-stamp leaves behind. #4 reads **"approved, not yet dispatched"**: the failure gone and nothing in its place. This is the state the ticket predicted. |

Both 1280×900, full page, Playwright MCP against `bin/rails server -p 3199` on the seeded dev
database.

`block-kit-card-over-a-retry.json` is the Slack card through all three states, rendered by the
same `Concierge::Slack::Card` the server calls:

```
1 · the failure          :hourglass: *Approved* … — not performed: Net::ReadTimeout: the billing API did not answer
2 · the queued retry     :hourglass: *Approved* … — a retry is queued — this card updates when it is performed
3 · after the job        :white_check_mark: *Executed* … by dana@acme.test
```

State 2 is read off the row rather than from an `executing:` flag, on purpose. `executing:`
is knowable only to the caller that queued a *first* execution; a retry is not that, because
it has already deleted something every other surface was showing.

## Tests

`make verify` — rubocop 250 files, no offenses; **575 runs, 2088 assertions, 0 failures, 0
errors, 0 skips** (566 runs on `main`, so **9 new tests**).

**Mutation check, twice — the seam and the stamp fail independently.**

1. Reverted `retry_execution` to `main`'s signature and body (no `execute:` keyword):
   **8 errors**, in six files —

   ```
   Concierge::ApprovalIntakeTest#test_retry_can_clear_the_failure_without_executing,_for_a_surface_that_defers_it
   Concierge::ApprovalIntakeTest#test_a_deferred_retry_says_so_on_the_row,_because_it_erased_the_failure_that_was_there
   Concierge::ProposalExecutionJobTest#test_a_retry_deferred_to_this_job_performs,_and_needs_no_retry_failed_of_its_own
   Concierge::ProposalExecutionJobTest#test_a_deferred_retry_that_fails_again_records_the_new_failure,_not_the_old_silence
   Concierge::ProposalExecuteTest#test_a_refusal_ends_a_queued_retry_even_when_it_writes_nothing_else_to_the_row
   Concierge::SlackCardTest#test_a_card_redrawn_over_a_queued_retry_says_a_retry_is_queued,_not_that_nothing_is_wrong
   ProposalsAdminTest#test_a_retry_queued_from_somewhere_else_is_visible_here,_where_the_failure_used_to_be
   Concierge::ScopeIsolationTest#test_a_retry_deferred_to_a_job_re-attempts_its_own_cell_and_no_other
   ```

   The ninth new test — *retrying inline stays the default, and leaves no queued-retry stamp
   behind* — stays green, and should: it guards the admin's unchanged behaviour, which the
   mutation does not change.

2. Kept the `execute:` seam but dropped only the `execution_retry_queued_at` write:
   **4 failures**, which is the display half on its own —

   ```
   Concierge::ApprovalIntakeTest#test_a_deferred_retry_says_so_on_the_row,_…
   Concierge::ProposalExecuteTest#test_a_refusal_ends_a_queued_retry_…
   Concierge::SlackCardTest#test_a_card_redrawn_over_a_queued_retry_…
   ProposalsAdminTest#test_a_retry_queued_from_somewhere_else_is_visible_here,_…
   ```

Reverted, green again both times.

**The load-bearing invariant.** `test/scope_isolation_test.rb` passes (36 runs, 236
assertions) and was *extended*, not tested beside it. A deferred retry is a second way for one
cell's work to cross a process boundary as a bare proposal id — and unlike a first execution it
starts from a row that has already failed, so aiming at the wrong one would re-attempt a
neighbour's action nobody asked to have re-attempted. *`a retry deferred to a job re-attempts
its own cell and no other`* puts `billing/Acme` and `billing/Globex` in the identical failed
state, retries only Acme, and asserts: Acme delivered once, Globex zero, `csm/Acme` zero, and
Globex's failure still on its row and still unqueued — nothing in the engine will re-attempt
it on its own.

## What I could not verify

- **A real Slack Retry button.** There isn't one, in the engine or the dummy host — the ticket
  says so, and this PR deliberately does not add one, because that is a surface decision and
  the ticket asked for the seam. So the deferring caller in every check above is a `runner`
  script and the test suite, not a signed interactivity POST. The endpoint half of that path
  is the same one #4999 measured; what is new here is the seam it would call.
- **A real Slack workspace.** With no `SLACK_BOT_TOKEN` the dummy answers the Web API with a
  local stand-in. The card payloads in `block-kit-card-over-a-retry.json` are the real `Card`
  output for the real rows, but nothing was rendered by Slack.
- **A real LLM.** `ANTHROPIC_API_KEY` was unset, so the dummy ran its scripted chat. Nothing
  here touches the model path — the proposals are seeded — but this was not exercised against
  a live model.
- **A production queue.** ActiveJob's `:async` adapter, in the server's own thread pool. The
  case this stamp exists for — an enqueue that fails, or a queue that is down, leaving the
  stamp as the only record — was exercised by leaving the row stamped and never running the
  job (screenshot 01), not by taking a real broker down.
- **`Proposal::Execute` writing the clear twice.** On a refusal path the row now takes a
  second `update_columns` to drop the stamp. That is one extra UPDATE on a refusal, measured
  by nothing here; it was chosen over threading the column through five call sites because a
  refusal that returns without touching the row (`:no_executor`, `:agent_disabled`) has no
  other write to attach it to.
