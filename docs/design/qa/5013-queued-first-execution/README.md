# QA — the admin queue can tell a queued execution from an undispatched one

The defect (ty-5013, filed while giving `retry_execution` a row-backed queued state in #5007):
#4999 moved Slack's Approve to `ApprovalIntake.approve(…, execute: false)` +
`ProposalExecutionJob`, and told the card it had queued something with
`Slack::Card.new(proposal, executing: true)` — a **caller-supplied** flag, because only the
caller that queued it knew. `/concierge/admin/proposals` is not that caller. An approved row
whose execution was sitting on a queue rendered **"approved, not yet dispatched"** — the same
words as an approval nobody handed to anything. #5007 had added `execution_retry_queued_at`
for exactly this, but only the retry path stamped it.

## Reproduced first

A scratch integration test (deleted before commit) drove the real signed
`POST /concierge/slack/interactions` Approve and then loaded the admin queue:

```
assert_enqueued_with(job: Concierge::ProposalExecutionJob) { post "/concierge/slack/interactions", … }
assert_equal "approved", proposal.reload.state

--- ADMIN SAYS ---
<td>
            approved, not yet dispatched
```

Enqueued, approved, and the screen says nothing was dispatched.

## The change

`Slack::Intake#hand_off_execution` stamps the row when it queues, so the queue view reads the
fact rather than being told it. Two decisions are load-bearing:

- **The column is renamed** `execution_retry_queued_at` → `execution_queued_at`
  (`db/migrate/20260101000019_…`). Both paths write it now; a name that says "retry" would be
  wrong for one of them, and two columns meaning "queued" is how a screen reads one and misses
  the other. `Proposal::Execute` already cleared it on every outcome, so nothing else changed.
- **The stamp is written *before* `perform_later`.** An inline queue adapter runs the job
  inside `perform_later`, and `Proposal::Execute` clears the stamp on its way out; stamping
  afterwards would mark a finished row queued with nothing left to clear it.
- **The `:failed` enqueue path does not stamp.** The rescue clears it (and swallows a failure
  to clear, like the card update does, so a reporting path cannot 500 a recorded decision).
  Nothing was enqueued, so nothing would ever clear a stamp left there — the queue would
  promise a job that does not exist, forever.

`Slack::Card`'s `executing:` flag stays as the in-request override, as the ticket asked; the
row is now the source for every *other* redraw, and both branches print one sentence.

## What was run

- `make verify` — rubocop clean (258 files), **616 runs, 2298 assertions, 0 failures, 0 errors**.
- Cross-`(agent, account)` isolation suite extended rather than tested beside: the "an
  execution deferred to a job performs into its own cell and no other" case now also asserts
  the queued marker lands on Acme's row only, and is gone once the job answers.

### Mutation testing (old behaviour restored, suite re-run, reverted)

| Mutation | Red |
|---|---|
| Drop the stamp in `hand_off_execution` (pre-#5013 behaviour) | **3** — `ScopeIsolationTest#an_execution_deferred_to_a_job_…`, `SlackAdminTest#the_proposals_queue_says_a_Slack-queued_execution_is_queued…`, `SlackIntakeTest#Approve_stamps_the_row_queued…` |
| Leave the stamp on the failed-enqueue path (drop `unstamp_queued`) | **2** — `SlackAdminTest#an_execution_that_could_not_be_queued_is_not_reported_as_queued`, `SlackIntakeTest#an_enqueue_that_fails_leaves_the_decision_and_no_promise_of_a_job` |

`make verify` green again after reverting both.

## Screenshots — a genuinely running `test/dummy`

`bin/rails db:prepare && bin/rails db:seed`, `bin/rails server -p 3117` from **this worktree**
(verified via `lsof` that the Puma process on 3117 held this worktree's
`test/dummy/storage/development.sqlite3` — a leftover server from another worktree answered the
first attempt and that screenshot was discarded).

Approvals were driven through the real `Concierge::Slack::Intake.handle` seam against the dev
database, with the demo's offline Slack transport. The only substitution is the **queue
adapter**, set per-job in the `rails runner` process: a non-draining adapter for the queued
shot and a raising one for the failed-enqueue shot. That is the state being photographed — a
queue that has accepted work and not run it, and a queue that would not take it at all.

| Screenshot | What it shows |
|---|---|
| `queued-first-execution.png` | #2, approved from Slack by `dana@acme.test`, reads **"queued to be performed at 2026-07-26 07:14:27 UTC — it clears when the executor reports back"**. Before this branch it read "approved, not yet dispatched". |
| `enqueue-failed-not-dispatched.png` | The distinction, on one screen: #2 still queued, and #1 — whose enqueue raised — reads **"approved, not yet dispatched"**, because nothing was queued and the row must not claim otherwise. |
| `after-the-executor-reports-back.png` | The job ran: #2 is in **Decided / executed**, the marker cleared, and #1 is still honestly undispatched. |

## What could not be verified

- **No live model.** `ANTHROPIC_API_KEY` is unset, so the dummy host used its scripted chat.
  Nothing in this change touches the model path, but nothing here exercised a real one either.
- **No real Slack workspace.** `SLACK_BOT_TOKEN` is unset, so `chat.update` went to the demo's
  local stand-in. The card wording change is covered by `slack_card_test.rb`, not by eyes on a
  real card.
- **No real background worker.** The dev queue adapter was substituted as described above; the
  job itself was drained with `perform_now`. The ordering property this fix depends on (stamp
  before enqueue, so an inline adapter cannot outrun it) is asserted in the test suite, not on
  a live Solid Queue / Sidekiq.
